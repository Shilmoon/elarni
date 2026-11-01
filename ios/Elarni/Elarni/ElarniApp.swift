import SwiftUI

@main
struct ElarniApp: App {
  @State private var model = IOSAppModel.shared
  var body: some Scene {
    WindowGroup { ContentView().environment(model).onOpenURL { model.acceptURL($0) } }
  }
}
