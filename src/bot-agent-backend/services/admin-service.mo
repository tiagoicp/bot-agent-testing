import Array "mo:core/Array";
import Principal "mo:core/Principal";

module {
  // Check if a principal is an admin
  public func isAdmin(principal : Principal, admins : [Principal]) : Bool {
    for (admin in admins.vals()) {
      if (admin == principal) {
        return true;
      };
    };
    return false;
  };

  // Initialize first admin (first caller becomes admin)
  public func initializeFirstAdmin(caller : Principal, admins : [Principal]) : [Principal] {
    if (admins.size() == 0 and caller != getAnonymousPrincipal()) {
      return Array.concat(admins, [caller]);
    };
    return admins;
  };

  // Validate new admin before adding
  public func validateNewAdmin(new_admin : Principal, caller : Principal, admins : [Principal]) : {
    #ok : ();
    #err : Text;
  } {
    if (caller == getAnonymousPrincipal()) {
      return #err("Anonymous users cannot be admins");
    };

    if (not isAdmin(caller, admins)) {
      return #err("Only admins can add new admins");
    };

    if (isAdmin(new_admin, admins)) {
      return #err("Principal is already an admin");
    };

    return #ok(());
  };

  // Add a new admin to the list
  public func addAdminToList(new_admin : Principal, admins : [Principal]) : [Principal] {
    return Array.concat(admins, [new_admin]);
  };

  private func getAnonymousPrincipal() : Principal {
    Principal.fromText("2vxsx-fae");
  };
};
