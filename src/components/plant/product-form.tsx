import { useRef, useState } from 'react';
import { Text, View } from 'react-native';
import { Button, ErrorText, Field, colors } from '@/components/ui';
import { toUserMessage } from '@/lib/errors';
import { PlantError, RequestIds, plantApi, validateProductForm, type FieldErrors, type Product } from '@/lib/plant';
import { useSession } from '@/lib/session-provider';

/** Create or edit a product (inline on the Products tab). */
export function ProductForm({ product, onSaved, onCancel }: { product: Product | null; onSaved: () => void; onCancel: () => void }) {
  const { client } = useSession();
  const [code, setCode] = useState(product?.code ?? '');
  const [description, setDescription] = useState(product?.description ?? '');
  const [uom, setUom] = useState(product?.uom ?? 'pcs');
  const [errors, setErrors] = useState<FieldErrors>({});
  const [busy, setBusy] = useState(false);
  const ids = useRef(new RequestIds());

  async function save() {
    const e = validateProductForm({ code, description, uom });
    if (Object.keys(e).length) {
      setErrors(e);
      return;
    }
    const input = { code: code.trim(), description: description.trim(), uom: uom.trim() || 'pcs' };
    const key = JSON.stringify([product?.id ?? null, input]);
    setBusy(true);
    setErrors({});
    try {
      await plantApi.saveProduct(client, product?.id ?? null, input, ids.current.get(key));
      ids.current.succeeded(key);
      onSaved();
    } catch (err) {
      ids.current.failed(key, err);
      if (err instanceof PlantError && (err.field === 'code' || err.field === 'description' || err.field === 'uom')) setErrors({ [err.field]: err.message });
      else setErrors({ form: err instanceof PlantError ? err.message : toUserMessage(err) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <View testID="product-form" style={{ gap: 12, borderWidth: 2, borderColor: colors.primary, borderRadius: 12, padding: 16 }}>
      <Text accessibilityRole="header" style={{ fontSize: 18, fontWeight: '700', color: colors.text }}>
        {product ? 'Edit product' : 'Add product'}
      </Text>
      <Field label="Code" testID="product-code" value={code} onChangeText={setCode} error={errors.code} autoCapitalize="characters" autoComplete="off" />
      <Field label="Description" testID="product-description" value={description} onChangeText={setDescription} error={errors.description} autoComplete="off" />
      <Field label="Unit of measure" testID="product-uom" value={uom} onChangeText={setUom} error={errors.uom} autoCapitalize="none" autoComplete="off" />
      {errors.form ? <ErrorText testID="product-form-error">{errors.form}</ErrorText> : null}
      <View style={{ flexDirection: 'row', gap: 12, flexWrap: 'wrap' }}>
        <Button title={product ? 'Save changes' : 'Create product'} testID="product-save" onPress={save} disabled={busy} busy={busy} />
        <Button title="Cancel" variant="secondary" testID="product-cancel" onPress={onCancel} disabled={busy} />
      </View>
    </View>
  );
}
