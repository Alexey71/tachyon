import { describe, expect, it } from 'vitest';
import { formatOutboundType } from '../formatOutboundType';

describe('formatOutboundType', () => {
  it('formats protocol with transport in uppercase parentheses', () => {
    expect(formatOutboundType('VLESS', 'xhttp')).toBe('VLESS (XHTTP)');
    expect(formatOutboundType('vless', 'tcp')).toBe('vless (TCP)');
    expect(formatOutboundType('VMess', 'ws')).toBe('VMess (WS)');
    expect(formatOutboundType('Trojan', 'grpc')).toBe('Trojan (GRPC)');
  });

  it('leaves protocol untouched if transport is not provided', () => {
    expect(formatOutboundType('VLESS')).toBe('VLESS');
    expect(formatOutboundType('Direct')).toBe('Direct');
    expect(formatOutboundType(undefined)).toBe('');
  });

  it('handles group types without adding transport', () => {
    expect(formatOutboundType('Priority (Авто)', 'tcp')).toBe(
      'Priority (Авто) (TCP)',
    );
    expect(formatOutboundType('URLTest (Авто)')).toBe('URLTest (Авто)');
  });
});
