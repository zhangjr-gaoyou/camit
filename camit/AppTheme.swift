import SwiftUI

/// 统一界面风格：圆角、阴影、配色
enum AppTheme {
    static let cardCornerRadius: CGFloat = 14
    static let chipCornerRadius: CGFloat = 12
    static let cardShadowRadius: CGFloat = 8
    static let cardShadowOpacity: Double = 0.06
    static let cardShadowY: CGFloat = 4

    static let accentBlue = Color.blue
    static let accentGreen = Color(hex: "34C759")

    /// 卡片背景（白底）
    static var cardBackground: Color { Color(.systemBackground) }

    /// 页面背景（浅灰）
    static var pageBackground: Color { Color(.systemGroupedBackground) }

    /// 次要文字
    static var secondaryText: Color { Color.secondary }

}
