import QtQuick
import qs.Commons

// Geometric hardware icons stay recognizable without a particular icon font.
Canvas {
    id: root
    property string name: "cpu"
    property color ink: Color.foreground
    implicitWidth: Style.space(28)
    implicitHeight: Style.space(28)
    onNameChanged: requestPaint()
    onInkChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
    onPaint: {
        const c = getContext("2d")
        c.reset()
        c.scale(width / 28, height / 28)
        c.strokeStyle = ink
        c.fillStyle = ink
        c.lineWidth = 1.5
        c.lineCap = "round"
        c.lineJoin = "round"
        function line(x1, y1, x2, y2) { c.beginPath(); c.moveTo(x1, y1); c.lineTo(x2, y2); c.stroke() }
        function circle(x, y, r) { c.beginPath(); c.arc(x, y, r, 0, Math.PI * 2); c.stroke() }
        if (name === "cpu") {
            c.strokeRect(7, 7, 14, 14)
            c.strokeRect(10, 10, 8, 8)
            for (let n = 9; n <= 19; n += 5) {
                line(n, 3, n, 7); line(n, 21, n, 25)
                line(3, n, 7, n); line(21, n, 25, n)
            }
        } else if (name === "gpu") {
            c.strokeRect(4, 8, 21, 13)
            line(2, 6, 2, 24); line(2, 21, 4, 21)
            circle(17, 14.5, 4)
            line(17, 12, 17, 17); line(14.5, 14.5, 19.5, 14.5)
            line(7, 11, 10, 11); line(7, 14, 10, 14)
            line(8, 21, 8, 24); line(11, 21, 11, 24)
        } else if (name === "memory") {
            c.strokeRect(3, 8, 22, 12)
            for (let x = 6; x <= 20; x += 7) c.strokeRect(x, 11, 4, 6)
            for (let x = 5; x <= 23; x += 3) line(x, 20, x, 23)
        } else if (name === "disk") {
            c.strokeRect(5, 3, 18, 22)
            circle(14, 12, 6)
            circle(14, 12, 1.5)
            line(14, 12, 20, 18)
            line(8, 22, 10, 22)
        } else if (name === "heat") {
            c.beginPath(); c.moveTo(10, 17); c.lineTo(10, 6)
            c.arc(14, 6, 4, Math.PI, Math.PI * 2)
            c.lineTo(18, 17); c.arc(14, 21, Math.sqrt(32), -Math.PI / 4, Math.PI * 1.25); c.closePath(); c.stroke()
            line(14, 9, 14, 21)
            c.beginPath(); c.arc(14, 21, 2, 0, Math.PI * 2); c.fill()
        } else if (name === "diskio") {
            c.strokeRect(5, 3, 18, 22)
            line(11, 8, 11, 20); line(8, 17, 11, 20); line(14, 17, 11, 20)
            line(17, 20, 17, 8); line(14, 11, 17, 8); line(20, 11, 17, 8)
        } else if (name === "net") {
            line(9, 4, 9, 23); line(4, 18, 9, 23); line(14, 18, 9, 23)
            line(19, 24, 19, 5); line(14, 10, 19, 5); line(24, 10, 19, 5)
        } else if (name === "vpn") {
            // Ring with a V, used for every tunnel type and both on/off states.
            circle(14, 14, 11)
            line(8.5, 8.5, 14, 20.5)
            line(14, 20.5, 19.5, 8.5)
        } else if (name === "ip") {
            circle(14, 14, 11)
            c.beginPath(); c.ellipse(9, 3, 10, 22); c.stroke()
            line(3, 14, 25, 14); line(5, 8.5, 23, 8.5); line(5, 19.5, 23, 19.5)
        } else if (name === "mouse") {
            c.strokeRect(3, 7, 20, 14)
            c.fillRect(23, 11, 2, 6)
            c.fillRect(6, 10, 5, 8)
        }
    }
}
