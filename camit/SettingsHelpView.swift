import SwiftUI

/// 各平台 API Key 注册申请说明
struct SettingsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    bailianSection
                    openaiSection
                    geminiSection
                }
                .padding(20)
            }
            .navigationTitle(L10n.settingsHelpTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.settingsClose) { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var bailianSection: some View {
        let isZh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.settingsHelpBailianTitle)
                .font(.headline)
                .foregroundStyle(.primary)

            if isZh {
                Text("""
                1. 开通百炼平台：登录 https://www.aliyun.com/product/bailian，点击「免费体验」，同意服务协议开通。

                2. 开通模型服务：在控制台「API-Key」选项中点击「创建API-Key」，若按钮未激活，需先点击提示开通模型服务，选择「确认开通，并领取免费额度」。

                3. 创建 API Key：模型服务开通后，再次点击「创建API-Key」，选择归属账号、业务空间，填写描述后确定，即可获取 API Key，点击复制保存。

                官网：https://help.aliyun.com/zh/model-studio/get-api-key
                """)
            } else {
                Text("""
                1. Open Bailian: Visit https://www.aliyun.com/product/bailian, click "Free Trial", accept the agreement.

                2. Enable model service: In console "API-Key" option, click "Create API-Key". If disabled, enable model service first and claim free quota.

                3. Create API Key: After enabling, click "Create API-Key", select account, workspace, fill description, then get and copy your API Key.

                Docs: https://help.aliyun.com/zh/model-studio/get-api-key
                """)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var openaiSection: some View {
        let isZh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.settingsHelpOpenAITitle)
                .font(.headline)
                .foregroundStyle(.primary)

            if isZh {
                Text("""
                1. 注册账号：访问 https://platform.openai.com/signup，创建 OpenAI 账号。

                2. 获取 API Key：登录后访问 https://platform.openai.com/api-keys，在 API Keys 页面点击「Create new secret key」创建密钥，复制保存（仅显示一次）。

                3. 充值：新账号需添加支付方式并充值才能调用 API。可在 Billing 页面管理。

                官网：https://platform.openai.com/docs
                """)
            } else {
                Text("""
                1. Sign up: Visit https://platform.openai.com/signup to create an OpenAI account.

                2. Get API Key: Log in and go to https://platform.openai.com/api-keys, click "Create new secret key", copy and save (shown only once).

                3. Billing: Add a payment method and add credits to use the API. Manage in Billing.

                Docs: https://platform.openai.com/docs
                """)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var geminiSection: some View {
        let isZh = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.settingsHelpGeminiTitle)
                .font(.headline)
                .foregroundStyle(.primary)

            if isZh {
                Text("""
                1. 登录：使用 Google 账号访问 https://aistudio.google.com/app/apikey

                2. 接受条款：首次使用需接受服务条款（2024 年已更新）。

                3. 创建 API Key：在 API Keys 页面，Google AI Studio 会为新手自动创建默认项目和 API Key。也可点击「Create API key」手动创建，复制保存。

                4. 注意：通过 AI Studio 最多可同时创建 10 个项目。

                官网：https://ai.google.dev/gemini-api/docs
                """)
            } else {
                Text("""
                1. Sign in: Visit https://aistudio.google.com/app/apikey with your Google Account.

                2. Accept terms: First-time users must accept the Terms of Service (updated 2024).

                3. Create API Key: On the API Keys page, Google AI Studio auto-creates a default project and key for new users. Or click "Create API key" to create manually, then copy and save.

                4. Note: Max 10 projects via AI Studio at a time.

                Docs: https://ai.google.dev/gemini-api/docs
                """)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    SettingsHelpView()
}
