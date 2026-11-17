// 05 AC-1..12 (web): a Unit Admin creates a shift, assigns machines, covers one occurrence, reads the board and sets a shift target;
// a Supervisor sees "My shift" on Home. Mutating tests run in fixture org U with throwaway E2E-<random> shifts and machines (the
// fixture shifts and ownership stay untouched); fixtures-reset retires the throwaways on dev.
import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { FIXTURE_PASSWORD as API_PASSWORD, requireApi, signIn as apiSignIn, uuid } from '../api/helpers';
import { SHIFT_FIXTURE, USERS, signIn, throwawayPlantCode } from './fixtures';

async function expectNoSeriousViolations(page: Page) {
  await expect(page).toHaveTitle('MouldTrack');
  const results = await new AxeBuilder({ page }).analyze();
  const bad = results.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

// The Stack keeps earlier screens mounted (hidden), so only visible elements count.
const tid = (page: Page, id: string) => page.locator(`[data-testid="${id}"]:visible`);
const prefix = (page: Page, p: string) => page.locator(`[data-testid^="${p}"]:visible`);

const addDays = (iso: string, n: number) => {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};

test.describe('Unit Admin plans shifts and assignments (AC-1, AC-5..9)', () => {
  test.beforeAll(() => requireApi());

  test('create a shift, assign a machine, cover tomorrow, read the board and set a shift target', async ({ page }) => {
    test.setTimeout(180_000);
    const shiftName = throwawayPlantCode();
    const machineCode = throwawayPlantCode();
    const ua = await apiSignIn(USERS.u1, API_PASSWORD);
    const made = await ua.client.rpc('pm_save_machine', {
      p_request_id: uuid(), p_id: null, p_code: machineCode, p_name: 'E2E shift machine', p_asset_tag: '', p_make: '', p_model: '', p_controller: '', p_line_id: null, p_status: 'active',
    });
    expect(made.data).toMatchObject({ ok: true });
    const machineId = made.data.id as string;

    await signIn(page, USERS.u1, API_PASSWORD);
    await tid(page, 'plant-link').click();
    await expect(tid(page, 'plant-tab-shifts')).toBeVisible();

    // Shifts tab: fixture shifts, client validation, then create.
    await tid(page, 'plant-tab-shifts').click();
    await expect(tid(page, 'shifts-add')).toBeVisible();
    for (const name of SHIFT_FIXTURE.orgU.shifts) await expect(prefix(page, 'shift-name-').filter({ hasText: name })).toHaveCount(1);
    await expect(prefix(page, 'shift-window-').filter({ hasText: '22:00 – 06:00' })).toContainText('Overnight');
    await expect(prefix(page, 'shift-status-').first()).toHaveText('Active'); // status is text
    await expectNoSeriousViolations(page);
    await tid(page, 'shifts-add').click();
    await tid(page, 'shift-save').click();
    await expect(page.getByText('Enter a name of 1 to 40 characters')).toBeVisible();
    await tid(page, 'shift-name').fill(shiftName);
    await tid(page, 'shift-start').fill('02:07');
    await tid(page, 'shift-end').fill('02:30');
    await tid(page, 'shift-save').click();
    await expect(page.getByText('Use 15-minute steps: :00, :15, :30 or :45')).toBeVisible();
    await tid(page, 'shift-start').fill('02:15');
    await expect(tid(page, 'shift-duration')).toHaveText('Duration: 15 min');
    await expectNoSeriousViolations(page);
    await tid(page, 'shift-save').click();
    const row = prefix(page, 'shift-row-').filter({ hasText: shiftName });
    await expect(row).toHaveCount(1);
    await expect(row).toContainText('02:15 – 02:30');

    // A second shift with the same name (any case) is refused by the server.
    await tid(page, 'shifts-add').click();
    await tid(page, 'shift-name').fill(shiftName.toLowerCase());
    await tid(page, 'shift-start').fill('03:00');
    await tid(page, 'shift-end').fill('03:15');
    await tid(page, 'shift-save').click();
    await expect(page.getByText('A shift with this name already exists')).toBeVisible();
    await tid(page, 'shift-cancel').click();

    // Assignments tab: the new shift has nobody; assign the machine to the fixture supervisor.
    await tid(page, 'plant-tab-assignments').click();
    await prefix(page, 'board-shift-').filter({ hasText: shiftName }).click();
    await expect(tid(page, 'board-heading')).toContainText(shiftName);
    const today = await tid(page, 'board-date').inputValue();
    expect(today).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    await expect(tid(page, 'board-unassigned-title')).toContainText('Unassigned this shift');
    await expect(tid(page, `board-source-${machineId}`)).toHaveText('No plan');
    await tid(page, `board-machine-${machineId}`).click();
    await tid(page, 'board-assign').click();
    await tid(page, 'assign-submit').click();
    await expect(tid(page, 'assign-sup-error')).toHaveText('Choose a supervisor');
    await prefix(page, 'assign-sup-').filter({ hasText: SHIFT_FIXTURE.orgU.supervisor }).click();
    await expectNoSeriousViolations(page);
    await tid(page, 'assign-submit').click();
    const group = prefix(page, 'board-group-').filter({ hasText: SHIFT_FIXTURE.orgU.supervisor });
    await expect(group).toContainText(machineCode);
    await expect(tid(page, `board-source-${machineId}`)).toHaveText('Plan');
    await expect(tid(page, 'board-actions')).toHaveCount(0); // selection cleared after the write

    // Cover tomorrow only: the reason is required; today's plan stays.
    await tid(page, 'board-date').fill(addDays(today, 1));
    await tid(page, `board-machine-${machineId}`).click();
    await tid(page, 'board-cover').click();
    await tid(page, 'cover-sup-none').click();
    await tid(page, 'cover-submit').click();
    await expect(page.getByText('Enter a reason of 1 to 200 characters')).toBeVisible();
    await tid(page, 'cover-reason').fill('E2E leave');
    await tid(page, 'cover-submit').click();
    await expect(tid(page, `board-source-${machineId}`)).toHaveText('Cover: E2E leave');
    await expect(tid(page, 'board-group-unassigned')).toContainText(machineCode);
    await expectNoSeriousViolations(page);
    await tid(page, 'board-date').fill(today);
    await expect(tid(page, `board-source-${machineId}`)).toHaveText('Plan');

    // A shift target on the machine page.
    await tid(page, 'plant-tab-machines').click();
    await tid(page, 'machines-search').fill(machineCode);
    await prefix(page, 'machine-open-').click();
    await expect(tid(page, 'targets-empty')).toHaveText('No target set');
    await tid(page, 'override-add').click();
    await prefix(page, 'override-shift-').filter({ hasText: shiftName }).click();
    await prefix(page, 'override-pick-').first().click();
    await expect(tid(page, 'target-form')).toContainText(`Set target for ${shiftName}`);
    await tid(page, 'target-pieces').fill('555');
    await tid(page, 'target-submit').click();
    const override = prefix(page, 'override-row-').filter({ hasText: shiftName });
    await expect(override).toContainText('Current: 555');
    await expect(override).toContainText('pcs/shift');
    await expectNoSeriousViolations(page);
  });
});

test.describe('Supervisor home shows My shift (AC-9)', () => {
  test.beforeAll(() => requireApi());

  test('the card names the shift and lists assigned machines; a Unit Admin has no card', async ({ page }) => {
    await signIn(page, USERS.u3, API_PASSWORD);
    await expect(tid(page, 'my-shift')).toBeVisible();
    await expect(tid(page, 'my-shift-state')).toHaveText(/^(Running now|Starts \d{1,2} \w{3} \d{4})$/);
    await expect(tid(page, 'my-shift-name')).toBeVisible();
    await expect(prefix(page, 'my-shift-machine-').first()).toBeVisible();
    await expect(tid(page, 'plant-link')).toHaveCount(0);
    await expectNoSeriousViolations(page);
  });

  test('a Unit Admin does not see the card', async ({ page }) => {
    await signIn(page, USERS.u1, API_PASSWORD);
    await expect(tid(page, 'plant-link')).toBeVisible();
    await expect(tid(page, 'my-shift')).toHaveCount(0);
  });
});
