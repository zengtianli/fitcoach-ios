import SwiftUI

enum AppIdentity {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "上门体育"
    }

    static let privacyURL = URL(string: "https://app-ios-fitcoach-ios.tianli.cyou/privacy.html")!
    static let supportURL = URL(string: "https://app-ios-fitcoach-ios.tianli.cyou/support.html")!
}

/// 登录前、教练端和学员端使用同一组公开说明入口。
struct PrivacySupportLinks: View {
    var body: some View {
        HStack(spacing: 24) {
            Link("隐私政策", destination: AppIdentity.privacyURL)
            Link("联系支持", destination: AppIdentity.supportURL)
        }
        .font(.footnote)
        .buttonStyle(.borderless)
    }
}
