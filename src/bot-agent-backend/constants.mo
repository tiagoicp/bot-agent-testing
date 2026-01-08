import Types "./types";

module {
  // Environment - important for dependency management (it can be local, test, staging, production)
  public let ENVIRONMENT : Types.Environment = #local;

  // 30 days in nanoseconds (30 * 24 * 60 * 60 * 1_000_000_000)
  public let THIRTY_DAYS_NS : Nat = 2_592_000_000_000_000;
};
