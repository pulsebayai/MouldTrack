import AsyncStorage from '@react-native-async-storage/async-storage';

// ---- Local draft: a reading form survives a failed or interrupted submit; cleared on success --------------------------------------------
export type ReadingDraft = { productId: string | null; counter: string; good: string; reject: string; remarks: string };
export const readingDraftKey = (machineId: string, shiftId: string, date: string, kind: 'opening' | 'closing') => `reading-draft:${machineId}:${shiftId}:${date}:${kind}`;

export async function loadReadingDraft(key: string): Promise<ReadingDraft | null> {
  try {
    const raw = await AsyncStorage.getItem(key);
    return raw ? (JSON.parse(raw) as ReadingDraft) : null;
  } catch {
    return null;
  }
}
export async function saveReadingDraft(key: string, d: ReadingDraft): Promise<void> {
  try {
    await AsyncStorage.setItem(key, JSON.stringify(d));
  } catch {
    /* a draft is a convenience; losing it must not block the form */
  }
}
export async function clearReadingDraft(key: string): Promise<void> {
  try {
    await AsyncStorage.removeItem(key);
  } catch {
    /* ignore */
  }
}
