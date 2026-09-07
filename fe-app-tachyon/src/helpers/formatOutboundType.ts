export function formatOutboundType(type?: string, transport?: string): string {
  const cleanType = (type || '').trim();
  const cleanTransport = (transport || '').trim().toUpperCase();

  if (!cleanType) {
    return cleanTransport ? `(${cleanTransport})` : '';
  }

  if (!cleanTransport) {
    return cleanType;
  }

  if (cleanType.toUpperCase().includes(`(${cleanTransport})`)) {
    return cleanType;
  }

  return `${cleanType} (${cleanTransport})`;
}
