// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

struct NetworkInfoStrings {
    let language: AppLanguage
    private func value(_ zh: String, _ traditional: String, _ en: String) -> String {
        if language == .zhHans { return zh }
        if language == .zhTW || language == .zhHK { return traditional }
        return en
    }
    var historyTitle: String { value("最近查询记录", "最近查詢記錄", "Recent lookups") }
    var historyCaption: String { value("本机保存最近 10 次实际查询，重启后保留；使用缓存不会重复记录。", "本機儲存最近 10 次實際查詢，重新啟動後保留；使用快取不會重複記錄。", "The last 10 actual lookups are saved on this Mac across restarts. Cached results do not add records.") }
    var historyEmpty: String { value("暂无记录，打开网络信息查询后会自动保存。", "暫無記錄，開啟網絡資訊查詢後會自動儲存。", "No history yet. Open network information to make a lookup.") }
    var copyRecord: String { value("复制记录", "複製記錄", "Copy record") }
    var deleteRecord: String { value("删除", "刪除", "Delete") }
    var clearHistory: String { value("清空记录", "清除記錄", "Clear history") }
    var panelEntry: String { value("在面板顶部显示网络信息标签", "在面板頂部顯示網絡資訊分頁", "Show the network information tab in the panel") }
    var detailsLabel: String { value("查询说明", "查詢說明", "About this lookup") }
    var open: String { value("打开网络信息", "開啟網絡資訊", "Open network information") }
    var summary: String { value("查询国内和国际出口 IP、归属地、运营商与 ASN。", "查詢國內與國際出口 IP、所在地、電訊商與 ASN。", "Check domestic and international exit IPs, location, ISP and ASN.") }
    var title: String { value("网络信息", "網絡資訊", "Network information") }
    var domestic: String { value("国内出口", "國內出口", "China destination") }
    var international: String { value("国际出口", "國際出口", "International destination") }
    var refresh: String { value("刷新", "重新整理", "Refresh") }
    var loading: String { value("正在查询…", "正在查詢…", "Checking…") }
    var location: String { value("归属地", "所在地", "Location") }
    var operatorName: String { value("运营商／所属组织", "電訊商／所屬組織", "ISP / organization") }
    var copy: String { value("复制 IP", "複製 IP", "Copy IP") }
    var copied: String { value("已复制", "已複製", "Copied") }
    var unknown: String { value("暂无数据", "暫無資料", "Unavailable") }
    var notChecked: String { value("尚未查询", "尚未查詢", "Not checked yet") }
    var updated: String { value("更新于", "更新於", "Updated") }
    var stale: String { value("结果已过期，请刷新", "結果已過期，請重新整理", "Outdated result — refresh to check") }
    var lookupFailed: String { value("IP 已获取，归属信息查询失败", "已取得 IP，所在地資訊查詢失敗", "IP found; details lookup failed") }
    var failed: String { value("查询失败，请稍后刷新重试", "查詢失敗，請稍後重試", "Could not connect. Refresh to retry.") }
    var timedOut: String { value("请求超时，请刷新重试", "請求逾時，請重新整理", "Request timed out. Refresh to retry.") }
    var rateLimited: String { value("查询服务限流，请稍后重试", "查詢服務已達限額，請稍後重試", "Service rate limit reached. Try again later.") }
    var invalid: String { value("服务返回的数据无效", "服務傳回的資料無效", "The service returned invalid data.") }
    var sameIP: String { value("两个探测节点看到的出口 IP 相同", "兩個探測節點看到的出口 IP 相同", "Both probes observed the same exit IP.") }
    var note: String { value("展示访问各节点时对方看到的 IPv4，遵循系统代理与 VPN 分流。切换代理后请手动刷新；结果不代表所有国内或国际流量。", "顯示存取各節點時對方看到的 IPv4，遵循系統代理與 VPN 分流。切換代理後請手動重新整理；結果不代表所有國內或國際流量。", "Shows the IPv4 seen by each probe, following system proxy and VPN routing. Refresh after changing proxy settings; these results do not represent every destination.") }
    var privacy: String { value("打开网络信息标签时联网，缓存 5 分钟。探测节点会接收请求，检测到的 IP 会发送至 ipwho.is 查询归属信息；归属地为估算值。", "開啟網絡資訊分頁時連線，快取 5 分鐘。探測節點會接收請求，偵測到的 IP 會傳送至 ipwho.is 查詢所在地資訊；所在地為估計值。", "Opening this view makes requests, cached for 5 minutes. Probes receive the request; observed IPs are sent to ipwho.is for estimated location and network details.") }
    var detailsSource: String { value("归属数据：ipwho.is", "所在地資料：ipwho.is", "Details: ipwho.is") }
    func failure(_ failure: NetworkInfoFailure) -> String {
        switch failure {
        case .invalidResponse: return invalid
        case .unavailable: return failed
        case .rateLimited: return rateLimited
        case .timedOut: return timedOut
        case .secureConnection: return value("无法与节点建立安全连接，请稍后重试", "無法與節點建立安全連線，請稍後重試", "Could not establish a secure connection. Try again later.")
        }
    }
}
