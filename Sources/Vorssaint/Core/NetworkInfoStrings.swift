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
    var historyEmpty: String { value("暂无记录，点击“刷新”查询后会保存。", "暫無記錄，點擊「重新整理」查詢後會儲存。", "No history yet. Click Refresh to make a lookup.") }
    var copyRecord: String { value("复制记录", "複製記錄", "Copy record") }
    var deleteRecord: String { value("删除", "刪除", "Delete") }
    var clearHistory: String { value("清空记录", "清除記錄", "Clear history") }
    var panelEntry: String { value("在面板顶部显示网络信息标签", "在面板頂部顯示網絡資訊分頁", "Show the network information tab in the panel") }
    var detailsLabel: String { value("查询说明", "查詢說明", "About this lookup") }
    var open: String { value("打开网络信息", "開啟網絡資訊", "Open network information") }
    var summary: String { value("查询国内和国际出口 IP、归属地、运营商与 ASN。", "查詢國內與國際出口 IP、所在地、電訊商與 ASN。", "Check domestic and international exit IPs, location, ISP and ASN.") }
    var title: String { value("网络信息", "網絡資訊", "Network information") }
    var restoredResult: String { value("显示上次保存的查询结果，点击刷新获取当前网络", "顯示上次儲存的查詢結果，點擊重新整理取得目前網絡", "Showing saved results. Click Refresh to check the current network.") }
    var topologyTitle: String { value("IP 网络拓扑", "IP 網絡拓撲", "IP network topology") }
    var thisMac: String { value("本机", "本機", "This Mac") }
    var exitObservation: String { value("出口观测 · 路径未验证", "出口觀測 · 路徑未驗證", "Observed exits · route unverified") }
    var topologyLegend: String { value("实线：本机接口 · 虚线框：出口观测，非实际路由", "實線：本機介面 · 虛線框：出口觀測，非實際路由", "Solid lines: local interfaces · Dashed box: observed exits, not actual routes") }
    var currentNetwork: String { value("当前网络", "目前網絡", "Current network") }
    var overview: String { value("查看本机地址、VPN 隧道与网络出口", "查看本機位址、VPN 通道與網絡出口", "Local addresses, VPN tunnels and network exits") }
    var vpnTitle: String { value("VPN / 隧道", "VPN / 通道", "VPN / tunnel") }
    var vpnNote: String { value("按接口展示隧道 IPv4 地址", "按介面顯示通道 IPv4 位址", "Tunnel IPv4 addresses by interface") }
    var vpnEmpty: String { value("暂无隧道 IPv4 地址", "暫無通道 IPv4 位址", "No tunnel IPv4 address") }
    var notRecorded: String { value("未记录", "未記錄", "Not recorded") }
    var time: String { value("时间", "時間", "Time") }
    var actions: String { value("操作", "操作", "Actions") }
    var localAndVPN: String { value("内网 / VPN", "內網 / VPN", "Local / VPN") }
    var localTitle: String { value("内网 IP", "內網 IP", "Local IP") }
    var localNote: String { value("本机网卡 IPv4 · 仅在本机读取", "本機網卡 IPv4 · 僅在本機讀取", "Local interface IPv4 · read on this Mac") }
    var localEmpty: String { value("暂无可用的内网 IPv4 地址", "暫無可用的內網 IPv4 位址", "No local IPv4 address available") }
    var localFailed: String { value("读取网卡地址失败，请刷新重试", "讀取網卡位址失敗，請重新整理", "Could not read interface addresses. Refresh to retry.") }
    var domestic: String { value("国内出口", "國內出口", "China destination") }
    var international: String { value("国际出口", "國際出口", "International destination") }
    var refresh: String { value("刷新", "重新整理", "Refresh") }
    var loading: String { value("正在查询…", "正在查詢…", "Checking…") }
    var location: String { value("归属地", "所在地", "Location") }
    var operatorName: String { value("运营商／所属组织", "電訊商／所屬組織", "ISP / organization") }
    var copy: String { value("复制 IP", "複製 IP", "Copy IP") }
    var copied: String { value("已复制", "已複製", "Copied") }
    var unknown: String { value("暂无数据", "暫無資料", "Unavailable") }
    var notChecked: String { value("尚未查询，点击刷新获取", "尚未查詢，點擊重新整理取得", "Not checked yet. Click Refresh") }
    var updated: String { value("更新于", "更新於", "Updated") }
    var lastResult: String { value("上次查询结果", "上次查詢結果", "Last query result") }
    var networkChanged: String { value("网络已变化，可手动刷新", "網絡已變化，可手動重新整理", "Network changed. Refresh manually to update.") }
    var lookupFailed: String { value("IP 已获取，归属信息查询失败", "已取得 IP，所在地資訊查詢失敗", "IP found; details lookup failed") }
    var failed: String { value("查询失败，请稍后刷新重试", "查詢失敗，請稍後重試", "Could not connect. Refresh to retry.") }
    var timedOut: String { value("请求超时，请刷新重试", "請求逾時，請重新整理", "Request timed out. Refresh to retry.") }
    var rateLimited: String { value("查询服务限流，请稍后重试", "查詢服務已達限額，請稍後重試", "Service rate limit reached. Try again later.") }
    var invalid: String { value("服务返回的数据无效", "服務傳回的資料無效", "The service returned invalid data.") }
    var sameIP: String { value("两个探测节点看到的出口 IP 相同", "兩個探測節點看到的出口 IP 相同", "Both probes observed the same exit IP.") }
    var note: String { value("展示访问各节点时对方看到的 IPv4，遵循系统代理与 VPN 分流。切换代理后请手动刷新；结果不代表所有国内或国际流量。", "顯示存取各節點時對方看到的 IPv4，遵循系統代理與 VPN 分流。切換代理後請手動重新整理；結果不代表所有國內或國際流量。", "Shows the IPv4 seen by each probe, following system proxy and VPN routing. Refresh after changing proxy settings; these results do not represent every destination.") }
    var privacy: String { value("仅点击“刷新”时联网查询，打开页面不会自动刷新。探测节点会接收请求，检测到的 IP 会发送至 ipwho.is 查询归属信息；归属地为估算值。", "僅點擊「重新整理」時連線查詢，開啟頁面不會自動重新整理。探測節點會接收請求，偵測到的 IP 會傳送至 ipwho.is 查詢所在地資訊；所在地為估計值。", "Requests are made only when you click Refresh; opening this view does not refresh results. Probes receive the request; observed IPs are sent to ipwho.is for estimated location and network details.") }
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
