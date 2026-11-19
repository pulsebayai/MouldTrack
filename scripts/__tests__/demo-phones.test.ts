// Guard (owner report 2026-11-19): the demo supervisors' phones (00011, 00012) collided with e2e orgDef(1)'s Unit Admins,
// so the API suite re-provisioned the demo Auth users into its own org. Every canonical fixture phone must belong to one identity.
import { DEMO_USERS } from '../dev-demo-spec';
import { SUPER_ADMINS, USERS } from '../fixtures-reset';
import { orgDef } from '../../e2e/api/helpers';

const orgDefPhones = Array.from({ length: 9 }, (_, i) => Object.values(orgDef(i + 1, `org ${i + 1}`).users).map((u) => u.phone)).flat();

describe('canonical fixture phones are unique across the demo tenant, fixtures and e2e orgs', () => {
  it('no demo phone is used by an e2e orgDef user', () => {
    const clash = DEMO_USERS.map((u) => u.phone).filter((p) => orgDefPhones.includes(p));
    expect(clash).toEqual([]);
  });
  it('no demo phone is used by a fixture user or Super Admin', () => {
    const fixture = [...USERS, ...SUPER_ADMINS].map((u) => u.phone);
    expect(DEMO_USERS.map((u) => u.phone).filter((p) => fixture.includes(p))).toEqual([]);
  });
  it('no fixture user or Super Admin phone is used by an e2e orgDef user', () => {
    const fixture = [...USERS, ...SUPER_ADMINS].map((u) => u.phone);
    expect(fixture.filter((p) => orgDefPhones.includes(p))).toEqual([]);
  });
});
