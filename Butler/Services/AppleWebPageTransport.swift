import Foundation
import Darwin

private final class WebPageNetworkPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

@MainActor struct AppleWebPageTransport: WebPageTransport {
    func fetch(_ url: URL) async throws -> (Data, String) {
        let url = try PublicWebPage.url(url.absoluteString)
        let host = url.host!
        // URLSession resolves independently. This preflight cannot pin the final endpoint.
        let lookup = Task.detached(priority: .utility) { try Self.checkAddresses(host) }
        try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() }
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: WebPageNetworkPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.timeoutInterval = 20
        request.setValue("text/html, text/plain, application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Butler-PublicPageReader/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebPageFailure("网站响应无效，未读取。") }
        guard http.statusCode == 200 else {
            if (300..<400).contains(http.statusCode) { throw WebPageFailure("网站要求跳转，未跟随。请在浏览器核对最终公开地址后重新提出读取。") }
            throw WebPageFailure("网站返回HTTP \(http.statusCode)，未读取；不会登录、绕过限制或自动重试。")
        }
        let mime = http.mimeType?.lowercased() ?? ""
        guard ["text/html", "text/plain", "application/xhtml+xml"].contains(mime) else {
            throw WebPageFailure("此链接不是HTML或纯文本网页，请使用文件或分享入口。")
        }
        if let charset = http.textEncodingName?.lowercased(), !["utf-8", "utf8", "us-ascii"].contains(charset) {
            throw WebPageFailure("此页面的文字编码暂不支持，请主动分享所需文字。")
        }
        guard response.expectedContentLength <= Int64(PublicWebPage.maxBytes) else { throw WebPageFailure("页面超过500 KB，未读取。") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < PublicWebPage.maxBytes else { throw WebPageFailure("页面超过500 KB，已停止读取，未提供部分结果。") }
            data.append(byte)
        }
        return (data, mime)
    }

    private nonisolated static func checkAddresses(_ host: String) throws {
        try Task.checkCancellation()
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else {
            throw WebPageFailure("域名暂时无法解析，未读取。")
        }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first, found = false
        while let entry = current {
            try Task.checkCancellation()
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                  PublicWebPage.isPublicAddress(String(cString: buffer)) else {
                throw WebPageFailure("域名解析到本地、内网或特殊用途地址，已拒绝读取。")
            }
            found = true; current = entry.pointee.ai_next
        }
        guard found else { throw WebPageFailure("域名没有可用的公开地址。") }
    }
}
