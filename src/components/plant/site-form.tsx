import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Button, Chip, ErrorText, Field, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { MSG, PlantError, RequestIds, plantApi, type Site } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';
import { TIMEZONES, timezoneLabel } from '@/lib/timezones';
import { Label } from './common';

type Errors = Partial<Record<'name' | 'timezone' | 'form', string>>;

/** First-visit "Set up your site" and the Site tab's edit form: one site per tenant in R1. */
export function SiteForm({ site, defaultTimezone, onSaved, timezoneLocked = false }: { site: Site | null; defaultTimezone: string; onSaved: () => void; timezoneLocked?: boolean }) {
  const { client } = useSession();
  const [name, setName] = useState(site?.name ?? '');
  const [timezone, setTimezone] = useState(site?.timezone ?? defaultTimezone);
  const [errors, setErrors] = useState<Errors>({});
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const ids = useRef(new RequestIds());
  const zones = TIMEZONES.includes(timezone) ? TIMEZONES : [timezone, ...TIMEZONES];

  async function save() {
    const n = name.trim();
    if (n.length < 1 || n.length > 80) {
      setErrors({ name: MSG.siteName });
      return;
    }
    const key = JSON.stringify([n, timezone]);
    setBusy(true);
    setErrors({});
    setSaved(false);
    try {
      await plantApi.saveSite(client, { name: n, timezone }, ids.current.get(key));
      ids.current.succeeded(key);
      setSaved(true);
      onSaved();
    } catch (e) {
      ids.current.failed(key, e);
      if (e instanceof PlantError && (e.field === 'name' || e.field === 'timezone')) setErrors({ [e.field]: e.message });
      else if (e instanceof PlantError && e.field === 'timezone_locked') setErrors({ timezone: e.message });
      else setErrors({ form: e instanceof PlantError ? e.message : toUserMessage(e) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <View testID="site-form" style={{ gap: 16 }}>
      <Text accessibilityRole="header" style={{ fontSize: 22, fontWeight: '700', color: colors.text }}>
        {site ? 'Site' : 'Set up your site'}
      </Text>
      {site ? null : (
        <Text style={{ fontSize: 16, color: colors.text }}>Machines, products and targets belong to your site. Name it and confirm its time zone.</Text>
      )}
      <Field label="Site name" testID="site-name" value={name} onChangeText={setName} error={errors.name} autoComplete="off" />
      <View style={{ gap: 8 }}>
        <Label>Time zone</Label>
        {timezoneLocked && site ? (
          <>
            <Text testID="site-tz-locked" style={{ fontSize: 17, color: colors.text }}>{timezoneLabel(site.timezone)}</Text>
            <Text testID="site-tz-locked-note" style={{ fontSize: 15, color: colors.text }}>The site timezone can&apos;t change once targets exist</Text>
          </>
        ) : (
          <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
            {zones.map((z) => (
              <Chip key={z} testID={`site-tz-${z}`} label={timezoneLabel(z)} selected={timezone === z} onPress={() => setTimezone(z)} />
            ))}
          </View>
        )}
        {errors.timezone ? <ErrorText testID="site-tz-error">{errors.timezone}</ErrorText> : null}
      </View>
      {errors.form ? <ErrorText testID="site-form-error">{errors.form}</ErrorText> : null}
      {saved ? (
        <Text testID="site-saved" accessibilityLiveRegion="polite" style={{ fontSize: 15, color: colors.text }}>
          Saved
        </Text>
      ) : null}
      <Button title={site ? 'Save site' : 'Create site'} testID="site-save" onPress={save} disabled={busy} busy={busy} />
    </View>
  );
}
