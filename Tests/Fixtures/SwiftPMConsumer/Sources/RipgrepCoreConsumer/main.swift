import RipgrepCore

enum ConsumerSmokeTestError: Error {
    case unexpectedResults
}

@main
struct RipgrepCoreConsumer {
    static func main() throws {
        var options = RipgrepOptions()
        options.pattern = "needle"
        options.useStdin = true

        let results = try RipgrepSearcher().search(
            options: options,
            stdin: "haystack\nneedle here\n"
        )
        guard results.hasMatch,
              results.summary.matchedLines == 1,
              results.summary.totalMatches == 1,
              results.files.first?.matches.first?.line == "needle here" else {
            throw ConsumerSmokeTestError.unexpectedResults
        }

        print("RipgrepCore consumer passed")
    }
}
