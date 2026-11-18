# Names of tenants whose handover is not enforced, except throwaway test tenants (names start with "e2e " or "E2E ": the fixture orgs A/B/S/U and
# the specs' own tenants insert directly, without a handover_setting row). Input: GET /rest/v1/tenant?select=name,handover_setting(required).
[.[] | select(.name | test("^(e2e|E2E) ") | not) | select((.handover_setting.required // false) | not) | .name]
