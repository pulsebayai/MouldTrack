import AsyncStorage from '@react-native-async-storage/async-storage';
import type { Priority } from './issues';

// ---- Local draft (D11): the report form survives a failed or interrupted submit; cleared on success ------------------------------------
export type ReportDraft = { categoryId: string | null; priority: Priority | null; description: string; stopped: boolean };
const draftKey = (machineId: string) => `issue-draft:${machineId}`;
export async function loadDraft(machineId: string): Promise<ReportDraft | null> {
  try {
    const raw = await AsyncStorage.getItem(draftKey(machineId));
    return raw ? (JSON.parse(raw) as ReportDraft) : null;
  } catch {
    return null;
  }
}
export async function saveDraft(machineId: string, d: ReportDraft): Promise<void> {
  try {
    await AsyncStorage.setItem(draftKey(machineId), JSON.stringify(d));
  } catch {
    /* a draft is a convenience; losing it must not block the form */
  }
}
export async function clearDraft(machineId: string): Promise<void> {
  try {
    await AsyncStorage.removeItem(draftKey(machineId));
  } catch {
    /* ignore */
  }
}
