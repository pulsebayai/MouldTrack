// 04 AC-1..13 (web): the Plant screens for a Unit Admin; blocked for a Supervisor.
// Mutating tests run in "e2e org U" (fixture plant) with throwaway E2E-<random> codes; the first-run site setup uses its own org
// (e2e api org 9) that has no site. fixtures-reset removes or retires throwaway rows on dev.
import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '../diagnostics';
import { FIXTURE_PASSWORD as API_PASSWORD, orgDef, provisionOrg, requireApi, service } from '../api/helpers';
import { PLANT_FIXTURE, USERS, signIn, throwawayPlantCode } from './fixtures';

async function expectNoSeriousViolations(page: Page) {
  await expect(page).toHaveTitle('MouldTrack');
  const results = await new AxeBuilder({ page }).analyze();
  const bad = results.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

// The Stack keeps earlier screens mounted (hidden), so only visible elements count.
const tid = (page: Page, id: string) => page.locator(`[data-testid="${id}"]:visible`);
const prefix = (page: Page, p: string) => page.locator(`[data-testid^="${p}"]:visible`);

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const human = (iso: string) => `${Number(iso.slice(8))} ${MONTHS[Number(iso.slice(5, 7)) - 1]} ${iso.slice(0, 4)}`;
function addDays(iso: string, n: number): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

async function openPlant(page: Page, phone: string) {
  await signIn(page, phone, API_PASSWORD);
  await tid(page, 'plant-link').click();
  await expect(page).toHaveURL(/\/plant$/);
  await expect(tid(page, 'plant-tab-machines')).toBeVisible();
}

test.describe('First visit: set up the site (AC-1, AC-2)', () => {
  const org = orgDef(9, 'e2e api org 9');
  async function clearPlant() {
    const sb = service();
    await sb.from('line').delete().eq('tenant_id', org.id);
    await sb.from('site').delete().eq('tenant_id', org.id);
  }
  async function openPlantNoSite(page: Page, phone: string) {
    await signIn(page, phone, API_PASSWORD);
    await tid(page, 'plant-link').click();
    await expect(page).toHaveURL(/\/plant$/);
  }
  test.beforeAll(async () => {
    requireApi();
    await provisionOrg(org);
    await clearPlant();
  });
  test.afterAll(async () => {
    await clearPlant();
  });

  test('a Unit Admin with no site is asked to set it up, then adds a line', async ({ page }) => {
    requireApi();
    await openPlantNoSite(page, org.users.ua1.phone);
    await expect(page.getByText('Set up your site')).toBeVisible();
    await expect(tid(page, 'plant-tab-machines')).toHaveCount(0); // nothing but the site form until a site exists
    await expectNoSeriousViolations(page);
    await tid(page, 'site-save').click();
    await expect(tid(page, 'site-name-error')).toHaveText('Enter a name of 1 to 80 characters');
    await tid(page, 'site-name').fill('E2E Setup Plant');
    await expect(tid(page, 'site-tz-Asia/Kolkata')).toContainText('✓');
    await tid(page, 'site-save').click();

    await expect(tid(page, 'plant-tab-machines')).toBeVisible();
    await expect(tid(page, 'machines-empty')).toHaveText('No machines yet — add your first machine');
    await tid(page, 'plant-tab-site').click();
    await expect(tid(page, 'site-name')).toHaveValue('E2E Setup Plant');
    await expectNoSeriousViolations(page);

    const line = throwawayPlantCode();
    await tid(page, 'line-new-name').fill(line);
    await tid(page, 'line-add').click();
    await expect(prefix(page, 'line-name-')).toHaveText(line);
    await tid(page, 'line-new-name').fill(line.toLowerCase());
    await tid(page, 'line-add').click();
    await expect(tid(page, 'line-new-name-error')).toHaveText('A line with this name already exists');
  });

});

test.describe('Unit Admin maintains the plant (AC-3..9, AC-13)', () => {
  test.beforeAll(() => requireApi());

  test('tabs, lists and detail pass accessibility checks and show the fixture plant', async ({ page }) => {
    await openPlant(page, USERS.u1);
    await expect(tid(page, 'machines-add')).toBeVisible();
    await expectNoSeriousViolations(page);
    await tid(page, 'machines-search').fill(PLANT_FIXTURE.machineWithTarget.code);
    const row = prefix(page, 'machine-row-');
    await expect(row).toHaveCount(1);
    await expect(prefix(page, 'machine-status-')).toHaveText('Active'); // status is text
    await tid(page, 'machines-search').fill('zzzz-no-such-machine');
    await expect(tid(page, 'machines-no-match')).toHaveText('No machines match');
    await tid(page, 'machines-search').fill(PLANT_FIXTURE.machineWithTarget.code);
    await prefix(page, 'machine-open-').click();
    await expect(page).toHaveURL(/\/plant\/machines\//);
    await expect(prefix(page, 'target-current-')).toContainText(`Current: ${PLANT_FIXTURE.machineWithTarget.pieces} pcs/shift`);
    await prefix(page, 'target-set-').click();
    await expect(tid(page, 'target-form')).toBeVisible();
    await expectNoSeriousViolations(page);
    await tid(page, 'target-cancel').click();
    await tid(page, 'machine-cancel').click();

    await tid(page, 'plant-tab-products').click();
    await expect(prefix(page, 'product-row-').first()).toBeVisible();
    await expectNoSeriousViolations(page);
    await tid(page, 'plant-tab-site').click();
    await expect(tid(page, 'site-name')).toHaveValue(PLANT_FIXTURE.site);
    await expect(prefix(page, 'line-name-').first()).toBeVisible();
    await expectNoSeriousViolations(page);
  });

  test('a machine without a target shows "No target set"', async ({ page }) => {
    await openPlant(page, USERS.u1);
    await tid(page, 'machines-search').fill(PLANT_FIXTURE.machineWithoutTarget.code);
    await prefix(page, 'machine-open-').click();
    await expect(tid(page, 'targets-empty')).toHaveText('No target set');
  });

  test('add a machine and a product, set, change and end a target, and see the history', async ({ page }) => {
    test.setTimeout(120_000);
    const mCode = throwawayPlantCode();
    const pCode = throwawayPlantCode();
    await openPlant(page, USERS.u1);

    // Product first (Products tab), then the machine.
    await tid(page, 'plant-tab-products').click();
    await tid(page, 'products-add').click();
    await tid(page, 'product-save').click();
    await expect(tid(page, 'product-code-error')).toBeVisible();
    await tid(page, 'product-code').fill(pCode);
    await tid(page, 'product-description').fill('E2E cap 28mm');
    await tid(page, 'product-save').click();
    await tid(page, 'products-search').fill(pCode);
    await expect(prefix(page, 'product-row-')).toHaveCount(1);
    await expect(prefix(page, 'product-status-')).toHaveText('Active');
    await expect(prefix(page, 'product-uom-')).toHaveText('pcs');

    await tid(page, 'plant-tab-machines').click();
    await tid(page, 'machines-add').click();
    await expect(page).toHaveURL(/\/plant\/machines\/new$/);
    await tid(page, 'machine-code').fill(mCode);
    await tid(page, 'machine-name').fill('E2E press');
    await tid(page, 'machine-make').fill('Haitian');
    await tid(page, 'machine-save').click();
    await expect(page).toHaveURL(/\/plant\/machines\/[0-9a-f-]{36}$/);
    await expect(tid(page, 'machine-status')).toHaveText('Active');
    await expect(tid(page, 'targets-empty')).toHaveText('No target set');
    await expectNoSeriousViolations(page);

    // Set a target from the plant date (prefilled), then schedule a change.
    await tid(page, 'target-add').click();
    await prefix(page, 'target-pick-').filter({ hasText: pCode }).click();
    const today = await tid(page, 'target-date').inputValue();
    expect(today).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    await tid(page, 'target-pieces').fill('1200');
    await tid(page, 'target-submit').click();
    await expect(prefix(page, 'target-current-')).toHaveText(`Current: 1,200 pcs/shift · from ${human(today)}`);

    await prefix(page, 'target-set-').click();
    await tid(page, 'target-pieces').fill('1300');
    await tid(page, 'target-date').fill(addDays(today, 3));
    await tid(page, 'target-submit').click();
    await expect(prefix(page, 'target-next-')).toHaveText(`Next: 1,300 pcs/shift from ${human(addDays(today, 3))}`);
    await expect(prefix(page, 'target-current-')).toContainText('1,200 pcs/shift');

    // The product cannot be retired while the target is in force (AC-4).
    await tid(page, 'machine-cancel').click();
    await tid(page, 'plant-tab-products').click();
    await tid(page, 'products-search').fill(pCode);
    await prefix(page, 'product-toggle-').click();
    await expect(tid(page, 'confirm-title')).toContainText(`Retire ${pCode}`);
    await tid(page, 'confirm-ok').click();
    await expect(tid(page, 'products-action-error')).toContainText(`End its targets first. Used on: ${mCode}`);

    // End the target: first the scheduled change, then today's target.
    await tid(page, 'plant-tab-machines').click();
    await tid(page, 'machines-search').fill(mCode);
    await prefix(page, 'machine-open-').click();
    await prefix(page, 'target-end-').click();
    await tid(page, 'target-date').fill(addDays(today, 3));
    await tid(page, 'target-submit').click();
    await expect(prefix(page, 'target-next-')).toHaveText(`Next: ends ${human(addDays(today, 3))}`);
    await prefix(page, 'target-end-').click();
    await tid(page, 'target-date').fill(today);
    await tid(page, 'target-submit').click();
    await expect(prefix(page, 'target-current-')).toHaveText('No current target');
    await expect(prefix(page, 'target-next-')).toHaveCount(0); // the scheduled change was already cancelled by the end

    // History keeps every version (set, change, two ends), newest first, with who recorded them.
    const history = prefix(page, 'target-history-');
    await expect(history).toHaveCount(4);
    await expect(history.filter({ hasText: 'Ended' })).toHaveCount(2);
    await expect(history.filter({ hasText: '1,200 pcs/shift' })).toHaveCount(1);
    await expect(history.filter({ hasText: '1,300 pcs/shift' })).toHaveCount(1);
    await expect(history.first()).toContainText('by Fixture Admin U1');
    await expectNoSeriousViolations(page);

    // Past dates are refused (AC-8), then retire and reinstate the machine behind confirmation (AC-3).
    await prefix(page, 'target-set-').click();
    await tid(page, 'target-pieces').fill('500');
    await tid(page, 'target-date').fill(addDays(today, -1));
    await tid(page, 'target-submit').click();
    await expect(tid(page, 'target-date-error')).toHaveText("Targets can't start in the past");
    await tid(page, 'target-cancel').click();

    await tid(page, 'machine-retire').click();
    await expect(tid(page, 'confirm-title')).toHaveText(`Retire ${mCode} · E2E press?`);
    await tid(page, 'confirm-cancel').click();
    await expect(tid(page, 'machine-status')).toHaveText('Active');
    await tid(page, 'machine-retire').click();
    await tid(page, 'confirm-ok').click();
    await expect(tid(page, 'machine-status')).toHaveText('Retired');
    await expect(tid(page, 'machine-save')).toHaveCount(0);
    await expect(tid(page, 'target-add')).toHaveCount(0);
    await tid(page, 'machine-reinstate').click();
    await tid(page, 'confirm-ok').click();
    await expect(tid(page, 'machine-status')).toHaveText('Active');

    // With every target ended the product can now be retired and brought back.
    await tid(page, 'machine-cancel').click();
    await tid(page, 'plant-tab-products').click();
    await tid(page, 'products-search').fill(pCode);
    await prefix(page, 'product-toggle-').click();
    await tid(page, 'confirm-ok').click();
    await expect(tid(page, 'products-no-match')).toBeVisible(); // retired products are hidden by default
    await expect(prefix(page, 'product-row-')).toHaveCount(0);
    await tid(page, 'products-show-retired').click();
    await expect(prefix(page, 'product-status-')).toHaveText('Retired');
    await prefix(page, 'product-toggle-').click();
    await tid(page, 'confirm-ok').click();
    await expect(prefix(page, 'product-status-')).toHaveText('Active');
  });

  test('duplicate codes and an in-use line are refused with the reason shown', async ({ page }) => {
    test.setTimeout(90_000);
    const mCode = throwawayPlantCode();
    const lineName = throwawayPlantCode();
    await openPlant(page, USERS.u1);

    await tid(page, 'plant-tab-site').click();
    await tid(page, 'line-new-name').fill(lineName);
    await tid(page, 'line-add').click();
    await expect(prefix(page, 'line-name-').filter({ hasText: lineName })).toHaveCount(1);

    await tid(page, 'plant-tab-machines').click();
    await tid(page, 'machines-add').click();
    await tid(page, 'machine-code').fill(mCode);
    await tid(page, 'machine-name').fill('E2E on a line');
    await tid(page, 'machine-line-none').waitFor();
    await page.locator('[data-testid^="machine-line-"]:visible', { hasText: lineName }).click();
    await tid(page, 'machine-save').click();
    await expect(page).toHaveURL(/\/plant\/machines\/[0-9a-f-]{36}$/);
    await tid(page, 'machine-cancel').click();

    // A second machine with the same code (any case) is refused next to the Code field (AC-3).
    await tid(page, 'machines-add').click();
    await tid(page, 'machine-code').fill(mCode.toLowerCase());
    await tid(page, 'machine-name').fill('E2E duplicate');
    await tid(page, 'machine-save').click();
    await expect(tid(page, 'machine-code-error')).toHaveText('This code is already in use');
    await tid(page, 'machine-cancel').click();

    // The line cannot be archived while the machine uses it (AC-2).
    await tid(page, 'plant-tab-site').click();
    const row = page.locator('[data-testid^="line-row-"]:visible', { hasText: lineName });
    await row.locator('[data-testid^="line-archive-"]').click();
    await expect(tid(page, 'confirm-title')).toHaveText(`Archive ${lineName}?`);
    await tid(page, 'confirm-ok').click();
    await expect(tid(page, 'lines-error')).toHaveText(`Move or retire its machines first. Machines: ${mCode}`);
  });
});

test.describe('Supervisor is blocked (AC-10, AC-13)', () => {
  test('no Plant link on Home, and typing the address shows Not allowed with no plant data', async ({ page }) => {
    requireApi();
    await signIn(page, USERS.u3, API_PASSWORD);
    await expect(tid(page, 'home-tenant')).toHaveText('e2e org U');
    await expect(tid(page, 'plant-link')).toHaveCount(0);
    await page.goto('/plant');
    await expect(tid(page, 'not-allowed')).toHaveText('Not allowed');
    await expect(tid(page, 'machines-add')).toHaveCount(0);
    await expect(prefix(page, 'machine-row-')).toHaveCount(0);
    await page.goto('/plant/machines/new');
    await expect(tid(page, 'not-allowed')).toBeVisible();
    await expect(tid(page, 'machine-form')).toHaveCount(0);
  });
});
