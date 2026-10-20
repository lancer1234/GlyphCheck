import SwiftUI

enum ToolGuidance {
    static let descriptions:[String:String]=[
        "scan":"先找缺字、空白與重複輪廓；這些線索不等於錯字。",
        "charset":"匯入 Glyphs 字集，檢查涵蓋範圍或執行 OCR 初篩。",
        "mapping":"追查已回報的錯字，確認是否是字碼互換。",
        "proof":"貼上文章，查看實際排版；左右捲動與反白同步。",
        "repair":"選擇修復來源，逐字驗收後匯出獨立修正版。",
        "team":"匯出核對任務、合併他人答案，保留有衝突的判定。"
    ]
}
@MainActor struct HomeStartView:View {
    @EnvironmentObject var m:Checker
    var body:some View {
        VStack(alignment:.leading,spacing:26) {
            VStack(alignment:.leading,spacing:10) {
                Image(systemName:"character.magnify").font(.system(size:36,weight:.light)).foregroundStyle(.tint)
                Text(m.t("檢查字形，從這裡開始")).font(.largeTitle.bold())
                Text(m.t("找缺字、核對誤植，或修復老字檔。所有檢查都在你的 Mac 上完成。")).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }.padding(.top,32)
            VStack(spacing:12) {
                action("開始檢查字檔","選擇 TTF、OTF 或字體集合，再逐字核對。","doc.badge.plus",prominent:true){m.chooseGoal("font");m.importPanel()}
                action("檢查一段文字","選擇字檔，再貼上文章；只檢查文章用到的字。","text.alignleft"){m.chooseGoal("text");m.importPanel()}
                action("繼續之前的進度","從 App 保存的進度繼續，或匯入他人分享的檔案。","clock.arrow.circlepath"){m.showProgressLibrary()}
            }
            HStack {Label(m.t("原字檔不會被覆寫，進度會自動保存。"),systemImage:"lock.shield").font(.caption).foregroundStyle(.secondary);Spacer();Button(m.t("第一次使用？查看指南")){m.showGuide=true}.buttonStyle(.link)}
        }.padding(.bottom,24)
    }
    func action(_ title:String,_ subtitle:String,_ symbol:String,prominent:Bool=false,perform:@escaping()->Void)->some View {
        Button(action:perform) {
            HStack(spacing:18) {
                Image(systemName:symbol).font(.title2).foregroundStyle(.tint).frame(width:34)
                VStack(alignment:.leading,spacing:6) {Text(m.t(title)).font(.headline);Text(m.t(subtitle)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                Spacer();Image(systemName:"chevron.right").foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
                .background(prominent ? Color.accentColor.opacity(0.07) : Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:14))
                .overlay(RoundedRectangle(cornerRadius:14).stroke(prominent ? Color.accentColor.opacity(0.35) : Color.clear,lineWidth:1))
        }.buttonStyle(.plain)
    }
}
@MainActor struct QuickGuideView:View {
    @EnvironmentObject var m:Checker
    let tools=[("scan","預掃描"),("charset","字集驗收"),("mapping","對應追查"),("proof","詞句檢查"),("repair","修復對照"),("team","多人核對")]
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Text(m.t("使用指南")).font(.title2.bold());Spacer();Button(m.t("完成")){m.showGuide=false}}
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    GroupBox(m.t("最簡單的開始方式")) {
                        VStack(alignment:.leading,spacing:10) {
                            Text(m.t("1. 在首頁選擇字檔，按「開始逐字核對」。"))
                            Text(m.t("2. 字形正確就按 Enter；看到別的字，輸入那個字再按 Enter。"))
                            Text(m.t("3. 隨時離開，下次從「我的進度」繼續。需要修復時才開啟工具箱。"))
                        }.font(.callout).padding(8).frame(maxWidth:.infinity,alignment:.leading)
                    }
                    Text(m.t("工具箱裡有什麼？")).font(.headline)
                    Text(m.t("匯入字檔後，在準備頁按「開啟工具箱」；逐字核對時從「工作台」進入。")).font(.callout).foregroundStyle(.secondary)
                    ForEach(tools,id:\.0) {key,title in VStack(alignment:.leading,spacing:5) {Text(m.t(title)).font(.headline);Text(m.t(ToolGuidance.descriptions[key] ?? "")).font(.callout).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading)}
                    Divider()
                    Text(m.t("自動辨識只提供線索，不代表正確或錯誤；人工驗收後才會用於修復。")).font(.callout).foregroundStyle(.secondary)
                }.padding(.trailing,8)
            }
        }.padding(24).frame(width:650,height:580)
    }
}
