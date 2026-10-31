import SwiftUI
import UniformTypeIdentifiers

struct ViewerView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var zoom: ZoomController

    private static let barSpace: CGFloat = 88

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.currentURL == nil {
                emptyState
            } else {
                ZoomableImage(image: model.image, zoom: zoom, bottomInset: Self.barSpace) {
                    (model.window?.windowController as? ViewerWindowController)?.contextMenu()
                }
                if model.loadFailed {
                    Text("Can’t open this photo")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, Self.barSpace)
                }
                ControlBar(model: model, zoom: zoom)
                    .padding(.bottom, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.open(url) }
            }
            return true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Button("Open Photo…") {
                if let url = AppDelegate.runOpenPanel() { model.open(url) }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// The Windows 7 viewer's bottom row, in glass: zoom, size | previous, slideshow, next | rotate | delete.
struct ControlBar: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var zoom: ZoomController
    @State private var showsZoom = false

    var body: some View {
        let hasImage = model.image != nil
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    BarButton(symbol: "plus.magnifyingglass", help: "Zoom") { showsZoom.toggle() }
                        .popover(isPresented: $showsZoom, arrowEdge: .top) { zoomPopover }
                    BarButton(
                        symbol: zoom.isFit ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                        help: zoom.isFit ? (zoom.isSmall ? "Fill Window" : "Actual Size (⌘0)") : "Fit to Window (⌘9)"
                    ) {
                        zoom.toggleSize()
                    }
                }
                .disabled(!hasImage)

                Spacer().frame(width: 12)

                HStack(spacing: 6) {
                    BarButton(symbol: "chevron.backward", help: "Previous (←)") { model.step(-1) }
                    Button { model.startSlideshow() } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Slideshow (F5)")
                    BarButton(symbol: "chevron.forward", help: "Next (→)") { model.step(1) }
                }

                Spacer().frame(width: 12)

                HStack(spacing: 6) {
                    BarButton(symbol: "rotate.left", help: "Rotate Left (⌘L)") { model.rotate(clockwise: false) }
                    BarButton(symbol: "rotate.right", help: "Rotate Right (⌘R)") { model.rotate(clockwise: true) }
                }
                .disabled(!hasImage)

                Spacer().frame(width: 12)

                BarButton(symbol: "trash", help: "Move to Trash (Delete)", tint: .red) { model.confirmTrash() }
            }
        }
    }

    private var zoomPopover: some View {
        VStack(spacing: 8) {
            ZoomSlider(
                value: Binding(
                    get: { log2(Double(zoom.magnification)) },
                    set: { zoom.set(CGFloat(pow(2, $0))) }
                ),
                range: log2(Double(ZoomController.range.lowerBound))...log2(Double(ZoomController.range.upperBound))
            )
            .frame(width: 220)
            Text("\(Int((zoom.magnification * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

// Drawn by hand: the system slider's knob disappears against the dark popover.
private struct ZoomSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    private let knob: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let track = max(geo.size.width - knob, 1)
            let share = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let offset = track * min(max(share, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: track, height: 4)
                    .offset(x: knob / 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: offset, height: 4)
                    .offset(x: knob / 2)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: offset)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let share = min(max((drag.location.x - knob / 2) / track, 0), 1)
                value = range.lowerBound + Double(share) * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 22)
    }
}

private struct BarButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(L(help))
    }
}
