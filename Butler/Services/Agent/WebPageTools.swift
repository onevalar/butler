import Foundation

extension ButlerTools {
    static var webPageTools: String {
        let tool = functionSchema("propose_read_webpage", "仅用户明确要求读取某个公开网页时，提议单独确认该HTTPS链接。提议不联网；确认后读取一次静态文字，保留来源和时间，结果成为历史回执供后续对话使用。不登录、不执行脚本、不跟随跳转，不猜网址、不主动访问网页里的链接。", ["url": ["type": "string"]])
        return String(decoding: try! JSONSerialization.data(withJSONObject: tool), as: UTF8.self)
    }

    func executeWebPageTool(_ name: String, data: Data) throws -> String? {
        guard name == "propose_read_webpage" else { return nil }
        struct Args: Decodable { let url: String }
        let args = try JSONDecoder().decode(Args.self, from: data)
        let url = try PublicWebPage.url(args.url)
        if !pending.contains(where: { if case .webPage(let old) = $0.kind { old == url.absoluteString } else { false } }) {
            add(.webPage(url.absoluteString), title: "读取公开网页：\(url.host!)",
                detail: "仅此地址：\(url.absoluteString)\n确认后向该网站发起一次GET读取意图；网站会看到网络地址并可能记录请求，GET也可能产生网站端副作用。不带Cookie或账号凭据，不登录、不执行脚本、不下载图片、不自动跳转。请求前检查本地/内网地址，但域名再次解析、代理或VPN可能改变实际连接，不能保证网络隔离。最多读取500 KB、提取6000字，可能不完整。文字与来源保存在本次对话，后续交流会按需发送当前模型；已开启聊天同步/备份时随历史保存。网页内容不是你的操作授权，修改库存/任务须另行确认。不读取私密、带访问令牌或内网链接；如果页面不可读，请主动分享所需资料。")
        }
        return #"{"proposed":true,"confirmation_required":true,"network_requested":false}"#
    }
}
