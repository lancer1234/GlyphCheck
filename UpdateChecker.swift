import Foundation
import AppKit

struct AppVersion:Comparable {
    let numbers:[Int]
    let prerelease:[String]
    init?(_ value:String) {
        var text=value
        if text.first=="v" {text.removeFirst()}
        let core=text.split(separator:"+",maxSplits:1,omittingEmptySubsequences:false)[0]
        let parts=core.split(separator:"-",maxSplits:1,omittingEmptySubsequences:false)
        let numeric=parts[0].split(separator:".",omittingEmptySubsequences:false)
        guard numeric.count==3 else{return nil}
        var n:[Int]=[]
        for part in numeric {guard !part.isEmpty,part.allSatisfy({$0.isASCII && $0.isNumber}),part.count==1 || part.first != "0",let v=Int(part) else{return nil};n.append(v)}
        let pre=parts.count==2 ? parts[1].split(separator:".",omittingEmptySubsequences:false).map(String.init) : []
        guard pre.allSatisfy({!$0.isEmpty && $0.allSatisfy{$0.isASCII && ($0.isLetter || $0.isNumber || $0=="-")}}) else{return nil}
        numbers=n;prerelease=pre
    }
    static func <(a:Self,b:Self)->Bool {
        for (x,y) in zip(a.numbers,b.numbers) {if x != y {return x<y}}
        if a.prerelease.isEmpty != b.prerelease.isEmpty {return !a.prerelease.isEmpty}
        for (x,y) in zip(a.prerelease,b.prerelease) {
            if x==y {continue}
            if let nx=Int(x),let ny=Int(y) {return nx<ny}
            if Int(x) != nil {return true};if Int(y) != nil {return false};return x<y
        }
        return a.prerelease.count<b.prerelease.count
    }
}

struct GitHubRelease:Decodable {
    let tag_name:String
    let html_url:String
    let draft:Bool
    let prerelease:Bool
}
enum UpdateResult:Equatable {case available(String,URL),current,noRelease}
enum UpdateFailure:LocalizedError {
    case rateLimited,server(Int),invalid,network
    var errorDescription:String? {
        switch self {
        case .rateLimited:return "GitHub 暫時限制查詢次數，請稍後再試。"
        case .server(let code):return "GitHub 查詢失敗（HTTP \(code)），請稍後再試。"
        case .invalid:return "更新資料格式或來源不正確，未開啟任何下載。"
        case .network:return "無法連線檢查更新，請檢查網路後重試。"
        }
    }
}
final class UpdateRedirectGuard:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {completionHandler(nil)}
}
enum ReleaseUpdates {
    static let endpoint=URL(string:"https://api.github.com/repos/lancer1234/GlyphCheck/releases/latest")!
    static func interpret(_ data:Data,status:Int,current:String)throws->UpdateResult {
        if status==404 {return .noRelease}
        if status==403 || status==429 {throw UpdateFailure.rateLimited}
        guard status==200 else{throw UpdateFailure.server(status)}
        guard data.count<1_000_000,let release=try? JSONDecoder().decode(GitHubRelease.self,from:data),
              !release.draft,!release.prerelease,let version=AppVersion(release.tag_name),version.prerelease.isEmpty,
              let local=AppVersion(current),let components=URLComponents(string:release.html_url),components.scheme=="https",components.host=="github.com",components.port==nil,components.user==nil,components.password==nil,components.query==nil,components.fragment==nil,
              let url=components.url,
              components.path=="/lancer1234/GlyphCheck/releases/tag/"+release.tag_name else{throw UpdateFailure.invalid}
        return local<version ? .available(release.tag_name,url) : .current
    }
    static func fetch(current:String,session supplied:URLSession?=nil)async throws->UpdateResult {
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=20;config.httpShouldSetCookies=false;config.urlCache=nil
        let owned=supplied==nil
        let session=supplied ?? URLSession(configuration:config,delegate:UpdateRedirectGuard(),delegateQueue:nil)
        defer {if owned {session.finishTasksAndInvalidate()}}
        var request=URLRequest(url:endpoint);request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept");request.setValue("2022-11-28",forHTTPHeaderField:"X-GitHub-Api-Version");request.setValue("GlyphCheck/"+current,forHTTPHeaderField:"User-Agent")
        do {
            let (data,response)=try await session.data(for:request)
            guard let http=response as? HTTPURLResponse,http.url==endpoint else{throw UpdateFailure.invalid}
            return try interpret(data,status:http.statusCode,current:current)
        } catch let error as UpdateFailure {throw error}
        catch {throw UpdateFailure.network}
    }
}

extension Checker {
    var currentAppVersion:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "1.5.0"}
    func checkForUpdates(manual:Bool=true) {
        guard !checkingUpdates else{return}
        checkingUpdates=true;updateStatus=t("正在檢查更新…");availableUpdateURL=nil
        Task {
            defer {checkingUpdates=false}
            var found=false
            do {
                switch try await ReleaseUpdates.fetch(current:currentAppVersion) {
                case .available(let version,let url):availableUpdateURL=url;updateStatus=t("有新版本可下載")+"："+version;found=true
                case .current:updateStatus=t("目前沒有較新的正式版本。")
                case .noRelease:updateStatus=t("GitHub 尚無可用的正式版本。")
                }
            } catch {updateStatus=t(error.localizedDescription)}
            if manual || found {
                let alert=NSAlert();alert.messageText=t("檢查更新");alert.informativeText=t("目前版本")+"："+currentAppVersion+"\n\n"+updateStatus
                if let url=availableUpdateURL {
                    alert.addButton(withTitle:t("開啟下載頁"));alert.addButton(withTitle:t("稍後"))
                    if alert.runModal() == .alertFirstButtonReturn {NSWorkspace.shared.open(url)}
                } else {alert.addButton(withTitle:t("好"));alert.runModal()}
            }
        }
    }
    func checkUpdatesOnLaunch() {
        guard !didCheckUpdatesOnLaunch else{return};didCheckUpdatesOnLaunch=true
        if persistRecent && UserDefaults.standard.bool(forKey:"checkUpdatesOnLaunch") {checkForUpdates(manual:false)}
    }
}
