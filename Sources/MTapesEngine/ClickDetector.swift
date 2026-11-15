import Foundation

/// Détecte clics, doubles-clics et glissers à partir d'échantillons du pointeur et de l'état des boutons.
/// Fonction pure (aucune autorisation requise : l'état des boutons se lit sans surveillance de l'entrée).
public struct ClickDetector {
    public struct Sample {
        public var t: Double
        public var x: Double
        public var y: Double
        public var left: Bool
        public var right: Bool
        public init(t: Double, x: Double, y: Double, left: Bool, right: Bool) {
            self.t = t; self.x = x; self.y = y; self.left = left; self.right = right
        }
    }

    public var doubleClickInterval = 0.40
    public var doubleClickDistance = 5.0
    public var dragDistance = 6.0

    private var leftDown: (t: Double, x: Double, y: Double)?
    private var rightDown: (t: Double, x: Double, y: Double)?
    private var lastClick: (t: Double, x: Double, y: Double)?
    private var wasLeft = false
    private var wasRight = false

    public init() {}

    public mutating func feed(_ s: Sample) -> [TapeEvent] {
        var out: [TapeEvent] = []

        if s.left && !wasLeft { leftDown = (s.t, s.x, s.y) }
        if !s.left && wasLeft, let down = leftDown {
            let dist = hypot(s.x - down.x, s.y - down.y)
            if dist > dragDistance {
                out.append(TapeEvent(t: down.t, kind: "drag", x: down.x, y: down.y, button: "left"))
                lastClick = nil
            } else {
                var kind = "click"
                if let last = lastClick, down.t - last.t <= doubleClickInterval,
                   hypot(down.x - last.x, down.y - last.y) <= doubleClickDistance {
                    kind = "doubleclick"
                    lastClick = nil
                } else {
                    lastClick = (down.t, down.x, down.y)
                }
                out.append(TapeEvent(t: down.t, kind: kind, x: down.x, y: down.y, button: "left"))
            }
            leftDown = nil
        }

        if s.right && !wasRight { rightDown = (s.t, s.x, s.y) }
        if !s.right && wasRight, let down = rightDown {
            out.append(TapeEvent(t: down.t, kind: "rightclick", x: down.x, y: down.y, button: "right"))
            rightDown = nil
        }

        wasLeft = s.left
        wasRight = s.right
        return out
    }
}
