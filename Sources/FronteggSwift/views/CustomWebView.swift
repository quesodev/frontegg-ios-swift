//
//  SwiftUIWebView.swift
//
//  Created by David Frontegg on 24/10/2022.
//

import Foundation
import WebKit
import SwiftUI
import AuthenticationServices


class CustomWebView: WKWebView, WKNavigationDelegate {
    var accessoryView: UIView?
    private let fronteggAuth: FronteggAuth = FronteggAuth.shared
    private let logger = getLogger("CustomWebView")
    private var lastResponseStatusCode: Int? = nil

    override var inputAccessoryView: UIView? {
        // remove/replace the default accessory view
        return accessoryView
    }


    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        logger.trace("navigationAction check for \(navigationAction.request.url?.absoluteString ?? "no Url")")
        if let url = navigationAction.request.url {
            let urlType = getOverrideUrlType(url: url)

            logger.info("urlType: \(urlType)")
            switch(urlType){

            case .SocialLoginRedirectToBrowser: do {
                let opened = await UIApplication.shared.open(url)
                if !opened {
                    let url = AuthorizeUrlGenerator().generate()
                    _ = webView.load(URLRequest(url: url))
                }
                return .cancel
            }
            case .HostedLoginCallback: do {
                return self.handleHostedLoginCallback(webView, url)
            }
            case .SocialOauthPreLogin: do {
                return self.setSocialLoginRedirectUri(webView, url)
            }
            default:
                return .allow
            }
        } else {
            logger.warning("failed to get url from navigationAction")
            self.fronteggAuth.isLoading = false
            return .allow
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        logger.trace("didStartProvisionalNavigation")
        if let url = webView.url {
            let urlType = getOverrideUrlType(url: url)

            logger.info("urlType: \(urlType)")

            if(fronteggAuth.externalLink != (urlType == .Unknown)) {
                fronteggAuth.externalLink = urlType == .Unknown
            }

            if(fronteggAuth.isLoading == false) {
                fronteggAuth.isLoading = true
            }

            logger.info("startProvisionalNavigation isLoading = \(fronteggAuth.isLoading)")
            logger.info("isExternalLink = \(fronteggAuth.externalLink)")
        } else {
            logger.warning("failed to get url from didStartProvisionalNavigation()")
            self.fronteggAuth.isLoading = false
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logger.trace("didFinish")
        if let url = webView.url {
            let urlType = getOverrideUrlType(url: url)
            logger.info("urlType: \(urlType), for: \(url.absoluteString)")


            if urlType == .loginRoutes || urlType == .Unknown {
                logger.info("hiding Loader screen")
                if(fronteggAuth.isLoading) {
                    fronteggAuth.isLoading = false
                }
            } else if let statusCode = self.lastResponseStatusCode {
                self.lastResponseStatusCode = nil;
                self.fronteggAuth.isLoading = false


                webView.evaluateJavaScript("JSON.parse(document.body.innerText).errors.join('\\n')") { [self] res, err in
                    let errorMessage = res as? String ?? "Unknown error occured"

                    logger.error("Failed to load page: \(errorMessage), status: \(statusCode)")
                    self.fronteggAuth.isLoading = false
                    let content = generateErrorPage(message: errorMessage, url: url.absoluteString,status: statusCode);
                    webView.loadHTMLString(content, baseURL: nil);
                }
            }
        } else {
            logger.warning("failed to get url from didFinishNavigation()")
            self.fronteggAuth.isLoading = false
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {

        if let response = navigationResponse.response as? HTTPURLResponse {
            if response.statusCode >= 400 && response.statusCode != 500, let url = response.url {
                let urlType = getOverrideUrlType(url: url)
                logger.info("urlType: \(urlType), for: \(url.absoluteString)")

                if(urlType == .internalRoutes && response.mimeType == "application/json"){
                    self.lastResponseStatusCode = response.statusCode
                    decisionHandler(.allow)
                    return
                }
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError _error: Error) {
        let error = _error as NSError
        let statusCode = error.code
        if(statusCode==102){
            // interrupted by frontegg webview
            return;
        }

        let errorMessage = error.localizedDescription;
        let url = "\(error.userInfo["NSErrorFailingURLKey"] ?? error.userInfo)"
        logger.error("Failed to load page: \(errorMessage), status: \(statusCode), \(error)")
        self.fronteggAuth.isLoading = false
        let content = generateErrorPage(message: errorMessage, url: url, status: statusCode);
        webView.loadHTMLString(content, baseURL: nil);
    }


    private func handleHostedLoginCallback(_ webView: WKWebView, _ url: URL) -> WKNavigationActionPolicy {
        logger.trace("handleHostedLoginCallback, url: \(url)")
        guard let queryItems = getQueryItems(url.absoluteString), let code = queryItems["code"] else {
            logger.error("failed to get extract code from hostedLoginCallback url")
            logger.info("Restast the process by generating a new authorize url")
            let url = AuthorizeUrlGenerator().generate()
            _ = webView.load(URLRequest(url: url))
            return .cancel
        }

        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                let success = await FronteggAuth.shared.handleHostedLoginCallback(code)

                if(!success){
                    let url = AuthorizeUrlGenerator().generate()
                    _ = webView.load(URLRequest(url: url))
                }
            }

        }
        return .cancel
    }


    private func setSocialLoginRedirectUri(_ webView:WKWebView, _ url:URL) -> WKNavigationActionPolicy {

        logger.trace("setSocialLoginRedirectUri()")
        let queryItems = [URLQueryItem(name: "redirectUri", value: URLConstants.generateSocialLoginRedirectUri(fronteggAuth.baseUrl))]
        var urlComps = URLComponents(string: url.absoluteString)!

        if(urlComps.query?.contains("redirectUri") ?? false){
            logger.trace("redirectUri exist, forward navigation to webView")
            return .allow
        }
        urlComps.queryItems = (urlComps.queryItems ?? []) + queryItems


        logger.trace("added redirectUri to socialLogin auth url \(urlComps.url!)")
        self.fronteggAuth.isLoading = true
        _ = webView.load(URLRequest(url: urlComps.url!))
        return .cancel
    }

}

