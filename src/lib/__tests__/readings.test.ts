import {
  attainmentText, closingStatusText, openingNote, formatCount, formatPct, parseWhole, readingApi, validateCavities, validateClosing, validateMax, validateOpening, validateReason, validateRemarks, MSG,
} from '@/lib/readings';

describe('readings: parsing and validation (mirrors the server messages)', () => {
  it('parses whole numbers typed by a person', () => {
    expect(parseWhole('1,250')).toBe(1250);
    expect(parseWhole(' 007 ')).toBe(7);
    expect(parseWhole('')).toBeNull();
    expect(parseWhole('12.5')).toBeNull();
    expect(parseWhole('-1')).toBeNull();
    expect(parseWhole('1e3')).toBeNull();
  });
  it('validates an opening reading', () => {
    expect(validateOpening({ productId: 'p', counter: '1000', remarks: '' })).toEqual({});
    expect(validateOpening({ productId: null, counter: 'x', remarks: 'a'.repeat(501) })).toEqual({ product_id: MSG.product, counter: MSG.counter, remarks: MSG.remarks });
    expect(validateOpening({ productId: 'p', counter: '1000000000001', remarks: '' }).counter).toBe(MSG.counter);
    expect(validateOpening({ productId: 'p', counter: '1000000000000', remarks: '' })).toEqual({});
  });
  it('validates a closing reading (good and reject are whole numbers up to 10,000,000)', () => {
    expect(validateClosing({ counter: '1250', good: '950', reject: '30', remarks: '' })).toEqual({});
    expect(validateClosing({ counter: '', good: '', reject: '', remarks: '' })).toEqual({ counter: MSG.counter, good: MSG.good, reject: MSG.reject });
    expect(validateClosing({ counter: '1', good: '10000001', reject: '0', remarks: '' }).good).toBe(MSG.good);
    expect(validateClosing({ counter: '1', good: '0', reject: '0', remarks: '' })).toEqual({});
  });
  it('validates a counter maximum, a number of cavities and a reason', () => {
    expect(validateMax('')).toBeNull();
    expect(validateMax('999999')).toBeNull();
    expect(validateMax('8')).toBe(MSG.max);
    expect(validateCavities('4')).toBeNull();
    expect(validateCavities('0')).toBe(MSG.cavities);
    expect(validateCavities('257')).toBe(MSG.cavities);
    expect(validateReason('  ')).toBe(MSG.reason);
    expect(validateReason('typo')).toBeNull();
    expect(validateRemarks('a'.repeat(500))).toBeNull();
  });
  it('formats counts and percentages', () => {
    expect(formatCount(1250000)).toBe('1,250,000');
    expect(formatCount(null)).toBe('-');
    expect(formatPct(79.17)).toBe('79.17%');
    expect(formatPct(null)).toBe('No target');
  });
});

describe('readings: RPC arguments', () => {
  const rpc = jest.fn(async () => ({ data: { ok: true, id: 'r1' }, error: null, status: 200 }));
  const client = { rpc } as never;
  beforeEach(() => rpc.mockClear());
  it('sends an opening with a trimmed optional remark', async () => {
    await readingApi.opening(client, { machineId: 'm', shiftId: 's', shiftDate: '2026-11-18', productId: 'p', counter: '1,000', remarks: '  ' }, 'rid');
    expect(rpc).toHaveBeenCalledWith('rd_opening', { p_request_id: 'rid', p_machine_id: 'm', p_shift_id: 's', p_shift_date: '2026-11-18', p_product_id: 'p', p_counter: 1000, p_remarks: null });
  });
  it('sends a closing', async () => {
    await readingApi.closing(client, { machineId: 'm', shiftId: 's', shiftDate: '2026-11-18', counter: '1250', good: '950', reject: '30', remarks: ' ok ' }, 'rid');
    expect(rpc).toHaveBeenCalledWith('rd_closing', expect.objectContaining({ p_counter: 1250, p_good: 950, p_reject: 30, p_remarks: 'ok' }));
  });
  it('sends a correction with only the fields of its kind', async () => {
    await readingApi.correct(client, { readingId: 'r', kind: 'opening', productId: 'p', counter: '5', good: '9', reject: '9', remarks: '', reason: ' typo ' }, 'rid');
    expect(rpc).toHaveBeenLastCalledWith('rd_correct', expect.objectContaining({ p_product_id: 'p', p_good: null, p_reject: null, p_reason: 'typo' }));
    await readingApi.correct(client, { readingId: 'r', kind: 'closing', productId: 'p', counter: '5', good: '9', reject: '1', remarks: '', reason: 'recount' }, 'rid2');
    expect(rpc).toHaveBeenLastCalledWith('rd_correct', expect.objectContaining({ p_product_id: null, p_good: 9, p_reject: 1 }));
  });
  it('sends counter settings and cavities', async () => {
    await readingApi.setCounter(client, 'm', 'pieces', '999999', 'a');
    expect(rpc).toHaveBeenLastCalledWith('rd_set_machine_counter', { p_request_id: 'a', p_machine_id: 'm', p_unit: 'pieces', p_max: 999999 });
    await readingApi.setCounter(client, 'm', 'shots', '', 'b');
    expect(rpc).toHaveBeenLastCalledWith('rd_set_machine_counter', expect.objectContaining({ p_max: null }));
    await readingApi.setCavities(client, 'm', 'p', '4', '2026-11-18', 'c');
    expect(rpc).toHaveBeenLastCalledWith('rd_set_cavities', expect.objectContaining({ p_cavities: 4, p_effective_from: '2026-11-18' }));
    await readingApi.endCavities(client, 'm', 'p', '2026-11-18', 'd');
    expect(rpc).toHaveBeenLastCalledWith('rd_end_cavities', expect.objectContaining({ p_effective_from: '2026-11-18' }));
  });
});

describe('8a labels (R3, R5, R7)', () => {
  it('attainment text: No target set only without a target, Not closed yet without a closing', () => {
    expect(attainmentText({ target: null, closing_status: 'missing', attainment_pct: null })).toBe('No target set');
    expect(attainmentText({ target: 1000, closing_status: 'missing', attainment_pct: null })).toBe('Not closed yet');
    expect(attainmentText({ target: 1000, closing_status: 'on_time', attainment_pct: 24 })).toBe('24.00%');
  });
  it('a missing closing is "Not due yet" while the occurrence runs and Missing afterwards; Early has its own label', () => {
    expect(closingStatusText('missing', true)).toBe('Not due yet');
    expect(closingStatusText('missing', false)).toBe('Missing');
    expect(closingStatusText('early', true)).toBe('Early');
  });
  it('opening note: plant time, Late only when flagged', () => {
    expect(openingNote({ recorded_at: 'x', late: true }, () => '08:30')).toBe('Opening recorded 08:30 · Late');
    expect(openingNote({ recorded_at: 'x', late: false }, () => '08:30')).toBe('Opening recorded 08:30');
  });
});
