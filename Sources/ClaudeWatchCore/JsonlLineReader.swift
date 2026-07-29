import Foundation

enum JsonlLineReader {
    static func forEachLineData(at url: URL, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        let newline = Data([0x0A])
        var buffer = Data()
        buffer.reserveCapacity(chunkSize * 2)
        var endOfFile = false

        while !endOfFile {
            autoreleasepool {
                let chunk: Data
                if #available(macOS 10.15.4, *) {
                    chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
                } else {
                    chunk = handle.readData(ofLength: chunkSize)
                }

                if chunk.isEmpty {
                    endOfFile = true
                    return
                }
                buffer.append(chunk)

                while let nlRange = buffer.firstRange(of: newline) {
                    let line = buffer[buffer.startIndex..<nlRange.lowerBound]
                    if !line.isEmpty { body(Data(line)) }
                    buffer.removeSubrange(buffer.startIndex...nlRange.lowerBound)
                }
            }
        }

        if !buffer.isEmpty { body(buffer) }
    }
}
