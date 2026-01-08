module {
  /// Environment configuration for the bot-agent application
  /// Determines which Schnorr key to use for key derivation and other environment-specific behavior
  public type Environment = {
    #local;
    #test;
    #staging;
    #production;
  };
};
