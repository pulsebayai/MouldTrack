/** Fixed IANA list offered when setting up a site (D6). The server validates the choice against pg_timezone_names. */
export const TIMEZONES: readonly string[] = [
  'Asia/Kolkata',
  'Asia/Dubai',
  'Asia/Karachi',
  'Asia/Dhaka',
  'Asia/Colombo',
  'Asia/Kathmandu',
  'Asia/Bangkok',
  'Asia/Singapore',
  'Asia/Shanghai',
  'Asia/Tokyo',
  'Asia/Seoul',
  'Australia/Sydney',
  'Pacific/Auckland',
  'Europe/London',
  'Europe/Paris',
  'Europe/Berlin',
  'Africa/Cairo',
  'Africa/Johannesburg',
  'America/Sao_Paulo',
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Los_Angeles',
  'UTC',
];

export const DEFAULT_TIMEZONE = 'Asia/Kolkata';

/** "Asia/Kolkata" -> "Asia / Kolkata" (readable, still the IANA id). */
export function timezoneLabel(id: string): string {
  return id.replace(/_/g, ' ').replace(/\//g, ' / ');
}
