import Foundation

enum BoundedConcurrency {
    /// Runs `operation` over `inputs` with at most `maximumConcurrentTasks`
    /// running at once, preserving input order in the returned array.
    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maximumConcurrentTasks: Int,
        operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        guard !inputs.isEmpty else { return [] }
        let limit = max(1, min(maximumConcurrentTasks, inputs.count))

        return await withTaskGroup(of: (Int, Output).self) { group in
            var nextIndex = 0
            var results = Array<Output?>(repeating: nil, count: inputs.count)

            while nextIndex < limit {
                let index = nextIndex
                let input = inputs[index]
                group.addTask { (index, await operation(input)) }
                nextIndex += 1
            }

            while let (index, output) = await group.next() {
                // `.some` preserves a legitimate nil when Output itself is Optional.
                results[index] = .some(output)

                if nextIndex < inputs.count {
                    let pendingIndex = nextIndex
                    let input = inputs[pendingIndex]
                    group.addTask { (pendingIndex, await operation(input)) }
                    nextIndex += 1
                }
            }

            return results.enumerated().map { index, result in
                guard let result else {
                    preconditionFailure("Missing bounded map result at index \(index)")
                }
                return result
            }
        }
    }
}
