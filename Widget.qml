import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import "Layout.js" as Layout
import "."

Panel {
    id: root
    moduleName: "anso.statusline"
    manageIpc: false
    property bool attached: false
    property string settingsError: ""
    readonly property bool vertical: bar ? bar.vertical : false
    readonly property var preferences: Layout.normalize(settings)
    readonly property var hostWindow: QsWindow.window
    property real availableWidth: Layout.availableWidth(root, hostWindow ? hostWindow.contentItem : null, Style.space(12))
    readonly property bool fittedGraphs: preferences.graphs && fullWidth <= availableWidth
    readonly property var gpuAdapters: Layout.adapters(s)
    readonly property var diskMounts: (s.disk || {}).mounts || []
    // Free space, compact: 0.9G, 169G, 1.2T.
    function freeSpace(bytes) {
        if (!Number.isFinite(bytes)) return "—"
        const g = bytes / 1073741824
        return g >= 1000 ? (g / 1024).toFixed(1) + "T" : g >= 10 ? Math.round(g) + "G" : g.toFixed(1) + "G"
    }
    readonly property var metricIds: preferences.metrics.reduce((ids, id) => {
        if (id === "gpu") {
            const usage = gpuAdapters.length
                ? gpuAdapters.filter(g => Layout.gpuEnabled(settings, "gpuVisibility", g.id)).map(g => "gpu:" + g.id)
                : ["gpu"]
            const temperatures = preferences.metrics.indexOf("heat") >= 0
                ? gpuAdapters.filter(g => Layout.gpuEnabled(settings, "gpuTemperatureVisibility", g.id)).map(g => "gpuHeat:" + g.id)
                : []
            return ids.concat(usage, temperatures)
        }
        if (id === "disk") return ids.concat(diskMounts.length ? diskMounts.map(m => "disk:" + m.path) : ["disk"])
        if (id === "heat") {
            const temperatures = settings.cpuTemperature !== false ? ["cpuHeat"] : []
            if (preferences.metrics.indexOf("gpu") < 0)
                temperatures.push(...gpuAdapters.filter(g => Layout.gpuEnabled(settings, "gpuTemperatureVisibility", g.id)).map(g => "gpuHeat:" + g.id))
            return ids.concat(temperatures)
        }
        return ids.concat(id)
    }, [])
    readonly property real fullWidth: measuredWidth(metricIds.length, preferences.graphs)
    readonly property int fittedCount: {
        for (let count = metricIds.length; count > 0; count--)
            if (measuredWidth(count, fittedGraphs) <= availableWidth) return count
        return 0
    }
    function metricLabel(metric) {
        return metric.name
    }
    function barInkFor(ink, foreground, transparent) {
        if (!transparent || 0.2126 * foreground.r + 0.7152 * foreground.g + 0.0722 * foreground.b > 0.5) return ink
        return Qt.rgba(ink.r * 0.3 + foreground.r * 0.7,
            ink.g * 0.3 + foreground.g * 0.7,
            ink.b * 0.3 + foreground.b * 0.7, 1)
    }
    function barInk(ink) { return barInkFor(ink, barForeground, bar && bar.transparent) }
    // Space between metrics on the bar.
    readonly property real metricGap: Style.space(12)
    // The widest text each kind of reading can show; values are laid out at this
    // width so a reading growing from "9%" to "10%" doesn't shift its neighbours.
    function widestReading(metric) {
        return ({percent: "100%", free: "888G", temp: "100°C", rate: "↓88.8MB/s ↑88.8MB/s", toggle: "OFF", ip: "888.888.888.888"})[metric.kind] || metric.value
    }
    function readingWidth(metric) {
        return Math.ceil(Math.max(bodyMetrics.advanceWidth(metric.value), bodyMetrics.advanceWidth(widestReading(metric))))
    }
    function measuredWidth(count, graphs) {
        let result = Style.space(12) + Math.max(0, count - 1) * metricGap
        for (let i = 0; i < count; i++) {
            const metric = metrics[metricIds[i]] || {name: "GPU", value: "—"}
            const name = metricLabel(metric)
            const labelWidth = metric.icon ? Style.space(16) : Math.ceil(captionMetrics.advanceWidth(name))
            const readingWidth = root.readingWidth(metric)
            result += labelWidth + Style.space(5) + (graphs
                ? Math.max(readingWidth + Style.space(12), Style.space(preferences.chartWidth))
                : readingWidth + Style.space(4))
        }
        return result
    }
    FontMetrics { id: bodyMetrics; font.family: Style.font.family; font.pixelSize: Style.font.body }
    FontMetrics { id: captionMetrics; font.family: Style.font.family; font.pixelSize: Style.font.caption }
    readonly property color cpuColor: Metrics.palette("green", "color2", Color.accent)
    readonly property color memoryColor: Metrics.palette("magenta", "color5", Color.accent)
    readonly property color gpuColor: Metrics.palette("blue", "color4", Color.accent)
    readonly property color heatColor: Metrics.palette("yellow", "color3", Color.urgent)
    readonly property color netColor: Metrics.palette("cyan", "color6", Color.accent)
    readonly property color vpnColor: Metrics.palette("green", "color2", Color.accent)
    readonly property color batteryColor: !Number.isFinite((s.mouseBattery || {}).percent)
        ? barForeground
        : Number((s.mouseBattery || {}).percent) <= 20
            ? Metrics.palette("red", "color1", Color.urgent)
            : Metrics.palette("green", "color2", Color.accent)
    readonly property var net: s.net || ({})
    readonly property var s: Metrics.sample
    readonly property var metrics: {
        const result = {
            cpu: {kind: "percent", name: "CPU", value: Metrics.percent(s.cpu), ink: cpuColor, chart: "cores"},
            disk: {kind: "percent", name: "DISK", value: Metrics.percent((s.disk || {}).percent), ink: Metrics.palette("cyan", "color6", cpuColor), chart: "meter", amount: (s.disk || {}).percent},
            memory: {kind: "percent", name: "MEM", value: Metrics.percent(s.memory.percent), ink: memoryColor, chart: "meter", amount: s.memory.percent},
            gpu: {kind: "percent", name: "GPU", value: "—", ink: gpuColor, chart: "sparkline", history: []},
            cpuHeat: {kind: "temp", name: "CPU", value: Metrics.temp(s.cpuTemperature), ink: heatColor, chart: "sparkline", history: Metrics.history.cpuTemp},
            diskio: {kind: "rate", name: "I/O", value: "↓" + Metrics.speed((s.disk || {}).readRate, true) + " ↑" + Metrics.speed((s.disk || {}).writeRate, true), ink: Metrics.palette("cyan", "color6", cpuColor), chart: ""},
            net: {kind: "rate", name: "NET", value: "↓" + Metrics.speed(net.rxRate, true) + " ↑" + Metrics.speed(net.txRate, true), ink: netColor, chart: "sparkline",
                history: Metrics.history.netRx, ceiling: Math.max(1e5, ...Metrics.history.netRx.map(p => p.value || 0))},
            vpn: Metrics.vpnLinks.length
                ? {kind: "toggle", name: "VPN", value: "ON", ink: vpnColor, chart: ""}
                : {kind: "toggle", name: "VPN", value: "OFF", ink: barForeground, dim: true, chart: ""},
            ip: {kind: "ip", name: "IP", value: net.publicIp || "—", ink: netColor, chart: ""},
            mouse: {kind: "percent", name: "G703", value: Metrics.percent((s.mouseBattery || {}).percent), ink: batteryColor, dim: !Number.isFinite((s.mouseBattery || {}).percent), chart: ""}
        }
        gpuAdapters.forEach((gpu, index) => {
            const label = gpuAdapters.length > 1 ? "GPU" + index : "GPU"
            const history = Metrics.history.gpus[gpu.id] || {}
            result["gpu:" + gpu.id] = {kind: "percent", name: label, value: Metrics.percent(gpu.percent), ink: gpuColor, chart: "sparkline", history: history.load || []}
            result["gpuHeat:" + gpu.id] = {kind: "temp", name: label, value: Metrics.temp(gpu.temperature), ink: heatColor, chart: "sparkline", history: history.temperature || []}
        })
        diskMounts.forEach(mount => {
            result["disk:" + mount.path] = {kind: "free", name: mount.label.toUpperCase(), value: freeSpace(mount.free),
                ink: Metrics.palette("cyan", "color6", cpuColor), chart: "meter", amount: mount.percent}
        })
        return result
    }
    implicitWidth: vertical ? Style.bar.sizeVertical : !Metrics.sessionEnabled || fittedCount === 0 ? Math.min(availableWidth, Style.space(42)) : Math.min(availableWidth, measuredWidth(fittedCount, fittedGraphs))
    implicitHeight: vertical ? Style.space(Metrics.sessionEnabled ? 62 : 30) : (bar ? bar.barSize : Style.bar.sizeHorizontal)
    Component.onCompleted: { Metrics.attach(settings); attached = true }
    Component.onDestruction: if (attached) Metrics.detach()
    onSettingsChanged: if (attached) Metrics.configure(settings)
    function save(values) {
        const next = Object.assign({}, settings, values)
        if (JSON.stringify(next) === JSON.stringify(settings)) { settingsError = ""; return }
        const api = bar ? bar.shell : null
        if (api && api.updateEntryInline(moduleName, next)) settingsError = ""
        else settingsError = "Could not save settings. Try again from the Omarchy bar."
    }

    WidgetButton {
        id: button
        anchors.fill: parent
        clip: true
        bar: root.bar
        text: "Anso Statusline"
        labelVisible: false
        tooltipText: !Metrics.sessionEnabled ? "Anso Statusline paused · click to open" : Metrics.stale ? "Anso Statusline · telemetry unavailable" : "Anso Statusline · click for details"
        onPressed: b => { if (b === Qt.RightButton) { detail.showSettings = true; root.open() } else root.toggle() }
        PulseText { visible: !Metrics.sessionEnabled || (!root.vertical && root.fittedCount === 0); anchors.centerIn: parent; text: "◌"; color: root.barForeground }
        Row {
            id: line
            anchors.centerIn: parent
            spacing: root.metricGap
            visible: !root.vertical && Metrics.sessionEnabled && root.fittedCount > 0
            opacity: Metrics.stale ? 0.4 : 1
            Repeater {
                model: root.metricIds.slice(0, root.fittedCount)
                Row {
                    id: metricRow
                    required property string modelData
                    readonly property var metric: root.metrics[modelData] || ({name: "GPU", value: "—", ink: root.gpuColor, chart: "", history: []})
                    readonly property color displayInk: root.barInk(metric.ink)
                    spacing: Style.space(5)
                    opacity: metric.dim ? 0.5 : 1
                    PulseIcon {
                        visible: !!metric.icon
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(16); height: Style.space(16)
                        name: metric.icon || ""
                        ink: metricRow.displayInk
                    }
                    PulseText {
                        visible: !metric.icon
                        anchors.verticalCenter: parent.verticalCenter
                        objectName: "pulseMetricLabel-" + modelData
                        text: root.metricLabel(metric)
                        color: root.barForeground
                        opacity: 0.65
                        font.pixelSize: Style.font.caption
                    }
                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        objectName: "pulseMetricChart-" + modelData
                        width: root.fittedGraphs ? Math.max(Style.space(root.preferences.chartWidth), root.readingWidth(metricRow.metric) + Style.space(12)) : root.readingWidth(metricRow.metric) + Style.space(4)
                        height: Style.space(23)
                        Item {
                            objectName: "pulseMetricGraph-" + modelData
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: Style.space(9)
                            visible: root.fittedGraphs
                            opacity: root.bar && root.bar.transparent ? 0.8 : 0.55
                            CoreBars { anchors.fill: parent; visible: metric.chart === "cores"; values: root.s.cores; ink: metricRow.displayInk; spacing: 1 }
                            Meter { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: Style.space(5); visible: metric.chart === "meter"; value: metric.amount; ink: metricRow.displayInk }
                            Sparkline { anchors.fill: parent; visible: metric.chart === "sparkline"; values: metric.history || []; ceiling: metric.ceiling || 100; ink: metricRow.displayInk }
                        }
                        PulseText {
                            id: value
                            anchors.top: parent.top
                            anchors.left: parent.left
                            objectName: "pulseMetricValue-" + modelData
                            text: metric.value
                            color: metricRow.displayInk
                        }
                    }
                }
            }
        }
        Column {
            visible: root.vertical && Metrics.sessionEnabled
            anchors.centerIn: parent
            opacity: Metrics.stale ? 0.4 : 1
            PulseText { text: "CPU"; font.pixelSize: Style.font.caption; color: root.barForeground }
            PulseText { text: Metrics.percent(root.s.cpu); font.pixelSize: Style.font.caption; color: root.cpuColor }
            PulseText { text: "MEM"; font.pixelSize: Style.font.caption; color: root.barForeground }
            PulseText { text: Metrics.percent(root.s.memory.percent); font.pixelSize: Style.font.caption; color: root.memoryColor }
        }
    }
    KeyboardPanel {
        id: panel
        anchorItem: button; owner: root; bar: root.bar; open: root.opened
        focusTarget: detail
        contentWidth: fittedContentWidth(Style.space(440))
        contentHeight: fittedContentHeight(detail.implicitHeight, Style.space(760))
        Detail {
            id: detail
            anchors.fill: parent
            settings: root.settings
            settingsError: root.settingsError
            onSaveRequested: values => root.save(values)
            cpuColor: root.cpuColor; memoryColor: root.memoryColor
            gpuColor: root.gpuColor; heatColor: root.heatColor
            onCloseRequested: root.close()
        }
    }
}
