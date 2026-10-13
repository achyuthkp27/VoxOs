import Darwin
import Foundation

/// Captures the main thread's call stack from another thread, so a stall in hang.log names the
/// function that was running instead of only a timestamp.
///
/// The main thread is suspended for the few microseconds it takes to copy its registers and walk
/// the frame-pointer chain. While it is suspended nothing here may allocate or take a lock: the
/// main thread could be holding the malloc lock, and waiting on it would deadlock the process.
/// So the walk writes into a buffer allocated up front, and symbols are looked up only after
/// the thread is running again.
final class MainThreadSampler {
    static let maxFrames = 48

    private let mainThread: thread_act_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private let frames: UnsafeMutablePointer<UInt>

    /// Captures the calling thread, so it must be created on the main thread (the watchdog's
    /// start() is). Off main it reads main's identity synchronously from there.
    convenience init() {
        if Thread.isMainThread {
            self.init(thread: pthread_self())
        } else {
            self.init(thread: DispatchQueue.main.sync { pthread_self() })
        }
    }

    private init(thread main: pthread_t) {
        mainThread = pthread_mach_thread_np(main)
        let top = UInt(bitPattern: pthread_get_stackaddr_np(main))
        stackHigh = top
        stackLow = top - UInt(pthread_get_stacksize_np(main))
        frames = .allocate(capacity: Self.maxFrames)
    }

    deinit { frames.deallocate() }

    /// Return addresses, innermost first, or empty when the thread could not be sampled.
    func sample() -> [UInt] {
        #if arch(arm64)
            guard thread_suspend(mainThread) == KERN_SUCCESS else { return [] }
            var state = arm_thread_state64_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                    thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
                }
            }
            var depth = 0
            if result == KERN_SUCCESS {
                frames[0] = Self.strip(UInt(state.__pc))
                frames[1] = Self.strip(UInt(state.__lr))
                depth = 2 + walk(from: UInt(state.__fp), into: frames + 2, capacity: Self.maxFrames - 2)
            }
            thread_resume(mainThread)
            return Array(UnsafeBufferPointer(start: frames, count: depth))
        #else
            return []
        #endif
    }

    /// Follows saved frame pointers: each frame stores [previous fp, return address]. Every
    /// pointer is checked against the main stack's bounds and must move outward, so a corrupt
    /// chain ends the walk instead of reading arbitrary memory.
    private func walk(from start: UInt, into out: UnsafeMutablePointer<UInt>, capacity: Int) -> Int {
        var fp = start
        var count = 0
        while count < capacity, fp & 0xF == 0, fp >= stackLow, fp + 16 <= stackHigh {
            let record = UnsafePointer<UInt>(bitPattern: fp)!
            let next = record[0]
            let returnAddress = Self.strip(record[1])
            if returnAddress == 0 { break }
            out[count] = returnAddress
            count += 1
            guard next > fp else { break }
            fp = next
        }
        return count
    }

    /// Clears pointer-authentication bits a signed return address may carry.
    private static func strip(_ address: UInt) -> UInt { address & 0x0000_7FFF_FFFF_FFFF }

    /// One line per frame: image, offset into it (for `atos` against the dSYM) and the nearest
    /// symbol dladdr knows. Runs after the thread has been resumed.
    static func describe(_ addresses: [UInt]) -> [String] {
        addresses.enumerated().map { index, address in
            var info = Dl_info()
            // The return address points after the call; one byte back stays inside the caller.
            let lookup = index == 0 ? address : address - 1
            guard dladdr(UnsafeRawPointer(bitPattern: lookup), &info) != 0 else {
                return String(format: "%2d  ?  0x%lx", index, address)
            }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            let base = UInt(bitPattern: info.dli_fbase)
            let symbol = info.dli_sname.map { demangle(String(cString: $0)) } ?? "?"
            return String(format: "%2d  %@ +0x%lx  %@", index, image, address - base, symbol)
        }
    }

    private typealias Demangler =
        @convention(c) (
            UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
        ) -> UnsafeMutablePointer<CChar>?

    /// The runtime's own demangler, looked up rather than linked: it is exported but not declared.
    private static let demangler: Demangler? = {
        guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: Demangler.self)
    }()

    static func demangle(_ name: String) -> String {
        guard let demangler, name.hasPrefix("$s") || name.hasPrefix("_$s") else { return name }
        return name.withCString { pointer in
            guard let result = demangler(pointer, strlen(pointer), nil, nil, 0) else { return name }
            defer { free(result) }
            return String(cString: result)
        }
    }
}
