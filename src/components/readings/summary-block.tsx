import { Text, View } from 'react-native';
import { colors } from '@/components/ui';
import { FLAG_LABEL, formatCount, formatPct, type ReadingFlag, type SummaryInfo } from '@/lib/readings';

/** Flags are always text (never colour alone). */
export function FlagList({ flags, testID }: { flags: ReadingFlag[]; testID?: string }) {
  if (flags.length === 0) return null;
  return (
    <View testID={testID} style={{ gap: 2 }}>
      {flags.map((f) => (
        <Text key={f} testID={`${testID ?? 'flag'}-${f}`} style={{ fontSize: 14, fontWeight: '700', color: colors.text }}>⚑ {FLAG_LABEL[f]}</Text>
      ))}
    </View>
  );
}

export function summaryFlags(s: Pick<SummaryInfo, 'rollover' | 'needs_review' | 'over_reported'>, late: { opening?: boolean; closing?: boolean } = {}): ReadingFlag[] {
  const out: ReadingFlag[] = [];
  if (late.opening) out.push('late_opening');
  if (late.closing) out.push('late_closing');
  if (s.rollover) out.push('rollover');
  if (s.needs_review) out.push('needs_review');
  if (s.over_reported) out.push('over_reported');
  return out;
}

/** The production summary of one machine-occurrence: movement, good, reject, unaccounted, target and attainment, always together with the target. */
export function SummaryBlock({ s, testID, late }: { s: SummaryInfo; testID: string; late?: { opening?: boolean; closing?: boolean } }) {
  const row = { fontSize: 15, color: colors.text } as const;
  return (
    <View testID={testID} style={{ gap: 4 }}>
      <Text testID={`${testID}-target`} style={row}>Target: {s.target === null ? 'No target set' : formatCount(s.target)}</Text>
      <Text testID={`${testID}-movement`} style={row}>Counter movement: {s.movement_pieces === null ? 'Needs review' : `${formatCount(s.movement_pieces)} pieces`}</Text>
      <Text testID={`${testID}-good`} style={row}>Good: {formatCount(s.good)} · Reject: {formatCount(s.reject)}</Text>
      <Text testID={`${testID}-unaccounted`} style={row}>Unaccounted: {formatCount(s.unaccounted)}</Text>
      <Text testID={`${testID}-attainment`} style={{ fontSize: 17, fontWeight: '700', color: colors.text }}>Attainment: {formatPct(s.attainment_pct)}</Text>
      <FlagList testID={`${testID}-flags`} flags={summaryFlags(s, late)} />
    </View>
  );
}
