#if !os(macOS)
// Murmur's app layer needs AppKit. On other platforms only MurmurCore builds and tests.
@main
enum MurmurUnsupported {
    static func main() {
        print("Murmur runs on macOS. Only its MurmurCore library builds on this platform.")
    }
}
#endif
