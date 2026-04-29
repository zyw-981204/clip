enum LikeEscape {
    /// Escape `%`, `_`, and `\` for use in a `LIKE ? ESCAPE '\'` clause.
    /// Caller is responsible for wrapping the result with `%...%` for substring match.
    static func escape(_ q: String) -> String {
        var out = ""
        out.reserveCapacity(q.count)
        for ch in q {
            if ch == "\\" || ch == "%" || ch == "_" {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }
}
