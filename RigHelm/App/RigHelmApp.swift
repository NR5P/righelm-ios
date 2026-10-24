import SwiftUI

@main
struct RigHelmApp: App {
    @State private var rig = RigController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(rig)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: rig.enteredBackground()
            case .active: rig.enteredForeground()
            default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(RigController.self) private var rig

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if rig.target == nil {
                ConnectView()
            } else {
                MainTabs()
            }
        }
        .alert("Transmit is locked", isPresented: Bindable(rig).showLockedHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rig.transmitBlockReason ?? "Transmit is not available right now.")
        }
        .alert("Microphone access is off", isPresented: Bindable(rig).micPermissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow RigHelm to use the microphone in iOS Settings to talk through the phone.")
        }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            OperateView()
                .tabItem { Label("Operate", systemImage: "dial.medium") }
            ControlsView()
                .tabItem { Label("Controls", systemImage: "slider.horizontal.3") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
