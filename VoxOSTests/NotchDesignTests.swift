import AppKit
import SwiftUI
import Testing

@testable import VoxOS

/// The notch is judged by eye, but the things that make it look right are numbers: a silhouette
/// that scoops at the shoulders and rounds at the bottom, corners that grow with the surface, and a
/// waveform that is tallest in the middle. These pin those down so a refactor cannot flatten them.
@Suite
@MainActor
struct NotchDesignTests {

    // MARK: Silhouette

    private func contains(_ shape: NotchShape, _ rect: CGRect, _ x: CGFloat, _ y: CGFloat) -> Bool {
        shape.path(in: rect).contains(CGPoint(x: x, y: y))
    }

    @Test func shouldersAreScoopedOutOfTheTopCorners() {
        let shape = NotchShape(topCornerRadius: 14, bottomCornerRadius: 17)
        let rect = CGRect(x: 0, y: 0, width: 300, height: 60)
        // Right at the top corner the band is narrower than the screen-edge corner...
        #expect(!contains(shape, rect, 2, 1), "the outside of the left shoulder is cut away")
        #expect(!contains(shape, rect, 298, 1), "and so is the right")
        // ...and by one shoulder-radius down it has widened to the full body.
        #expect(contains(shape, rect, 14.5, 14))
        #expect(contains(shape, rect, 285, 14))
        // The flat top between the shoulders is solid.
        #expect(contains(shape, rect, 150, 1))
    }

    @Test func theShoulderIsACircleNotAPinchedCurve() {
        let shape = NotchShape(topCornerRadius: 20, bottomCornerRadius: 10)
        let rect = CGRect(x: 0, y: 0, width: 200, height: 80)
        // On a quarter circle centred on the screen edge, halfway down the boundary sits at
        // x = sqrt(20² − 10²) ≈ 17.3. A quadratic corner would put it near 15.
        #expect(!contains(shape, rect, 16.5, 10), "just outside the circle")
        #expect(contains(shape, rect, 18.2, 10), "just inside the circle")
    }

    @Test func bottomCornersAreRounded() {
        let shape = NotchShape(topCornerRadius: 14, bottomCornerRadius: 24)
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        #expect(!contains(shape, rect, 14.5, 99.5), "the very corner of the body is rounded off")
        #expect(!contains(shape, rect, 285, 99.5))
        #expect(contains(shape, rect, 150, 99), "the flat bottom is solid")
        #expect(contains(shape, rect, 14.5, 70), "the straight side is solid above the curve")
    }

    @Test func theShapeFillsItsRectAndStaysInsideIt() {
        let rect = CGRect(x: 10, y: 5, width: 260, height: 50)
        let bounds = NotchShape(NotchDesign.listening).path(in: rect).boundingRect
        #expect(abs(bounds.minX - rect.minX) < 0.01 && abs(bounds.maxX - rect.maxX) < 0.01)
        #expect(abs(bounds.minY - rect.minY) < 0.01 && abs(bounds.maxY - rect.maxY) < 0.01)
    }

    @Test func degenerateSizesNeverProduceNonsense() {
        for rect in [
            CGRect.zero, CGRect(x: 0, y: 0, width: 0, height: 40), CGRect(x: 0, y: 0, width: 20, height: 4),
            CGRect(x: 0, y: 0, width: 30, height: 200),
        ] {
            let bounds = NotchShape(NotchDesign.expanded).path(in: rect).boundingRect
            #expect(bounds.minX.isFinite && bounds.maxX.isFinite && bounds.minY.isFinite && bounds.maxY.isFinite)
            #expect(bounds.width <= rect.width + 0.01 && bounds.height <= rect.height + 0.01, "\(rect)")
        }
    }

    @Test func radiiAnimateTogether() {
        var shape = NotchShape(topCornerRadius: 10, bottomCornerRadius: 11)
        shape.animatableData = AnimatablePair(18, 31)
        #expect(shape.topCornerRadius == 18 && shape.bottomCornerRadius == 31)
    }

    // MARK: Tokens

    @Test func cornersGrowWithTheSurface() {
        #expect(NotchDesign.resting.shoulder < NotchDesign.listening.shoulder)
        #expect(NotchDesign.listening.shoulder < NotchDesign.expanded.shoulder)
        #expect(NotchDesign.resting.bottom < NotchDesign.listening.bottom)
        #expect(NotchDesign.listening.bottom < NotchDesign.expanded.bottom)
    }

    @Test func expandedCornerIsConcentricWithTheComposer() {
        #expect(NotchDesign.expanded.bottom == CGFloat(19 + 12), "composer radius plus its inset")
        #expect(NotchDesign.expandedBodyWidth < NotchDesign.expandedWidth)
    }

    @Test func waveformIsTallestInTheMiddleAndSymmetric() {
        let heights = (0..<NotchDesign.barWeights.count).map(NotchDesign.barHeight(at:))
        #expect(heights.count == 5)
        #expect(heights[2] == heights.max())
        #expect(heights[0] == heights[4] && heights[1] == heights[3])
        #expect(heights[0] < heights[1] && heights[1] < heights[2])
        #expect(heights.allSatisfy { $0 >= NotchDesign.barMinHeight })
        #expect(abs(heights[2] - 16.2) < 0.001, "7 + 10 × 0.92")
    }

    @Test func outOfRangeBarsFallBackToTheMinimum() {
        #expect(NotchDesign.barHeight(at: -1) == NotchDesign.barMinHeight)
        #expect(NotchDesign.barHeight(at: 99) == NotchDesign.barMinHeight)
    }

    @Test func waveformWidthIsFiveBarsAndFourGaps() {
        let expected: CGFloat = 5 * 3.5 + 4 * 3.5
        #expect(NotchDesign.waveformWidth == expected, "five bars and four gaps, 3.5 pt each")
    }

    @Test func liquidGlassIsTheDefaultMaterial() {
        #expect(NotchDesign.Material.resolve(nil) == .liquidGlass)
        #expect(NotchDesign.Material.resolve("nonsense") == .liquidGlass, "a bad stored value must not break the notch")
        #expect(NotchDesign.Material.resolve("solidBlack") == .solidBlack)
        #expect(NotchDesign.Material.allCases.count == 2)
        #expect(UserDefaults.standard.string(forKey: DefaultsKeys.notchMaterial) == "liquidGlass", "registered default")
    }

    @Test func theTopStaysSolidSoItMergesWithThePhysicalNotch() {
        #expect(NotchDesign.glassDarkStop > 0.3 && NotchDesign.glassDarkStop < 0.6)
    }

    @Test func replyPanelContentStaysInsideTheBandBody() {
        // The body is the frame minus a shoulder on each side; content must start inside it.
        #expect(AgentComposer.panelInset > NotchDesign.expanded.shoulder)
        #expect(AgentComposer.panelInset == NotchDesign.expanded.shoulder + 12, "12 pt inside the body edge")
        #expect(
            NotchDesign.expanded.bottom - (AgentComposer.panelInset - NotchDesign.expanded.shoulder)
                == AgentComposer.radius,
            "composer concentric with the bottom corner")
    }

    @Test func replyPanelFollowsItsContentWithinLimits() {
        #expect(
            AgentComposer.panelHeight(forContent: 0) == AgentComposer.panelMinHeight, "never smaller than the floor")
        #expect(AgentComposer.panelHeight(forContent: 100) == 100 + AgentComposer.panelChrome)
        #expect(
            AgentComposer.panelHeight(forContent: 1_000) == AgentComposer.panelMaxHeight, "never taller than the cap")
        #expect(AgentComposer.panelChrome > AgentComposer.minHeight, "chrome includes the composer")
    }

    // MARK: Snapshot (for looking at)

    /// Renders each state on a dark wallpaper under a menu bar, so the silhouette can be judged
    /// by eye. Writes PNGs only when VOXOS_SNAPSHOT_DIR is set; always checks the render is real.
    @Test func rendersEveryState() throws {
        let states: [(String, NotchDesign.Radii, CGFloat, CGFloat)] = [
            ("resting", NotchDesign.resting, 190, 37),
            ("listening", NotchDesign.listening, 318, 37),
            ("expanded", NotchDesign.expanded, NotchDesign.expandedWidth, 300),
        ]
        for (name, radii, width, height) in states {
            let renderer = ImageRenderer(content: NotchSnapshotView(radii: radii, width: width, height: height))
            renderer.scale = 2
            let image = try #require(renderer.nsImage, "\(name) failed to render")
            #expect(image.size.width > 100 && image.size.height > 40)
            if let dir = ProcessInfo.processInfo.environment["VOXOS_SNAPSHOT_DIR"],
                let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                let png = rep.representation(using: .png, properties: [:])
            {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("notch-\(name).png"))
            }
        }
    }
}

/// A stand-in for the real screen: wallpaper, a menu bar, and the notch hanging from its edge.
private struct NotchSnapshotView: View {
    let radii: NotchDesign.Radii
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let shape = NotchShape(radii)
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.24, blue: 0.36), Color(red: 0.42, green: 0.30, blue: 0.48)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(Color.black.opacity(0.25)).frame(height: 24).frame(maxHeight: .infinity, alignment: .top)

            shape.fill(NotchDesign.solid)
                .overlay(
                    shape.fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.035), .clear], startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 0.6)))
                )
                .overlay(
                    shape.stroke(NotchDesign.rim, lineWidth: NotchDesign.rimWidth)
                        .mask(
                            LinearGradient(
                                colors: [.clear, .white], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
                )
                .frame(width: width, height: height)
                .overlay(alignment: .leading) {
                    HStack(spacing: NotchDesign.barSpacing) {
                        ForEach(0..<5, id: \.self) { index in
                            RoundedRectangle(cornerRadius: NotchDesign.barWidth / 2)
                                .fill(Color(red: 0.62, green: 0.55, blue: 1.0).opacity(0.9))
                                .frame(width: NotchDesign.barWidth, height: NotchDesign.barHeight(at: index))
                        }
                    }
                    .padding(.leading, radii.shoulder + NotchDesign.contentInset)
                    .frame(height: 37)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .shadow(color: .black.opacity(0.28), radius: 6, y: 5)
        }
        .frame(width: width + 80, height: height + 50)
        .padding(0)
    }
}
