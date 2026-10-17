// Menu bar label: a neutral air-quality icon + PM2.5 as a number.
import PurifierCore
import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        // Depends only on PM2.5 and connectivity - the label is redrawn only then.
        let state = model.controller?.state
        let connection = model.controller?.connection ?? .connecting
        HStack(spacing: 4) {
            Image(systemName: "aqi.medium")
            Text(PanelFormat.menuBarTitle(pm25: state?.pm25, connection: connection))
                .monospacedDigit()
        }
    }
}
