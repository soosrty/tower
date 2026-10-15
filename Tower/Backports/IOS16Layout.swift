import SwiftUI

extension View {
    @ViewBuilder func towerGeometryGroup() -> some View {
        if #available(iOS 17, *) { geometryGroup() } else { self }
    }
}
