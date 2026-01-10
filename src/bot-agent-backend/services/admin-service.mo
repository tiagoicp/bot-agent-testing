import Array "mo:core/Array";
import Principal "mo:core/Principal";
import Result "mo:core/Result";

module {
  // Check if a principal is an admin
  public func isAdmin(principal : Principal, admins : [Principal]) : Bool {
    for (admin in admins.vals()) {
      if (admin == principal) {
        return true;
      };
    };
    false;
  };

  // Initialize first admin (first caller becomes admin)
  // IMPORTANT: TODO: review security implications before use by third parties
  // SECURITY WARNING: Ensure there isn't any chance of another party to front run the first caller to addAdmin().
  public func initializeFirstAdmin(caller : Principal, admins : [Principal]) : [Principal] {
    if (admins.size() == 0 and caller != getAnonymousPrincipal()) {
      Array.concat(admins, [caller]);
    } else {
      admins;
    };
  };

  // Validate new admin before adding
  public func validateNewAdmin(newAdmin : Principal, caller : Principal, admins : [Principal]) : Result.Result<(), Text> {
    if (caller == getAnonymousPrincipal()) {
      return #err("Anonymous users cannot be admins");
    };

    if (not isAdmin(caller, admins)) {
      return #err("Only admins can add new admins");
    };

    if (isAdmin(newAdmin, admins)) {
      #err("Principal is already an admin");
    } else {
      #ok(());
    };
  };

  // Add a new admin to the list
  public func addAdminToList(newAdmin : Principal, admins : [Principal]) : [Principal] {
    Array.concat(admins, [newAdmin]);
  };

  private func getAnonymousPrincipal() : Principal {
    Principal.fromText("2vxsx-fae");
  };
};
