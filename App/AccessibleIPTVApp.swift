import SwiftUI
import UIKit
import IPTVCore

@main
struct AccessibleIPTVApp: App {
	#if os(iOS)
	@UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
	#endif
	@StateObject private var model = AppModel.shared

	var body: some Scene {
		WindowGroup {
			MainView()
				.environmentObject(model)
				.fullScreenCover(item: $model.playing) { r in
					PlayerScreen(request: r).environmentObject(model)
				}
				.sheet(item: $model.info) { InfoSheet(info: $0) }
				.sheet(isPresented: Binding(get: { model.externalChoice != nil }, set: { if !$0 { model.externalChoice = nil } })) {
					let list = model.externalChoice ?? []
					ChoiceSheet(title: L("play_external"), options: list.map(\.0)) { UIApplication.shared.open(list[$0].1) }
				}
		}
	}
}

#if os(iOS)
/// Hands CarPlay its own scene; the phone's window stays with SwiftUI.
final class AppDelegate: NSObject, UIApplicationDelegate {
	func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
		let config = UISceneConfiguration(name: nil, sessionRole: session.role)
		if session.role == .carTemplateApplication { config.delegateClass = CarPlaySceneDelegate.self }
		return config
	}
}
#endif
