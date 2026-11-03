import SwiftUI
import ARKit
import SceneKit

struct ContentView: View {
    @StateObject private var model = CaptureModel()
    @State private var shareItem: ShareItem?

    var body: some View {
        ZStack(alignment: .bottom) {
            ARPreview(session: model.session)
                .ignoresSafeArea()

            if !model.isScanning {
                GuideOverlay()
                    .transition(.opacity)
            }

            VStack(spacing: 12) {
                Text("\(model.shotCount) photos")
                    .font(.title2.bold())
                Text(model.status)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)

                HStack(spacing: 16) {
                    Button(model.isScanning ? "Stop" : "Start") {
                        if model.isScanning {
                            model.stopScan()
                        } else {
                            model.startScan()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(model.isScanning ? .red : .green)

                    if !model.isScanning && model.shotCount > 0 {
                        Button("Export") {
                            if let url = model.zipScan() {
                                shareItem = ShareItem(url: url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
        }
        .animation(.easeOut(duration: 0.25), value: model.isScanning)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.startSession()
        }
        .sheet(item: $shareItem) { item in
            ActivityView(url: item.url)
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ARPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
