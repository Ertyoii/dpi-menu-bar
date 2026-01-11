enum DpiListParser {
    static func parse(_ bytes: [UInt8]) -> [Int] {
        var list: [Int] = []
        var i = 0
        while i + 1 < bytes.count {
            let value = (Int(bytes[i]) << 8) | Int(bytes[i + 1])
            if value == 0 {
                break
            }
            if (value >> 13) == 0b111 {
                let step = value & 0x1FFF
                if i + 3 >= bytes.count {
                    break
                }
                let last = (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
                if let previous = list.last {
                    var v = previous + step
                    while v <= last {
                        list.append(v)
                        v += step
                    }
                }
                i += 4
            } else {
                list.append(value)
                i += 2
            }
        }
        return list
    }
}
