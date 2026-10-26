import Foundation

public enum WorkoutStartPolicy {
    public static func shouldStart(isBackground: Bool, running: Bool, starting: Bool) -> Bool {
        !isBackground && !running && !starting
    }
}
