public enum ColorInterpretation: Sendable {
    case container
    case assume(PixelFormat)
    case inferFromComponentCount
}

public enum Region: Sendable {
    case pixels(x: Int, y: Int, width: Int, height: Int)
    case fraction(left: Double, top: Double, right: Double, bottom: Double)
}
