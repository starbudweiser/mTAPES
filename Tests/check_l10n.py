#!/usr/bin/env python3
"""Vérifie que les quatre tables de App/L10n.swift ont exactement les mêmes clés et les mêmes formats (%@, %d)."""
import re, sys
src = open(__file__.rsplit('/tests/', 1)[0] + '/App/L10n.swift', encoding='utf-8').read()
tables = {}
for lang in ('fr', 'en', 'es', 'it'):
    m = re.search(r'private static let %s: \[String: String\] = \[(.*?)\n    \]' % lang, src, re.S)
    if not m: sys.exit(f'table {lang} introuvable')
    pairs = re.findall(r'"([\w.]+)":\s*"((?:[^"\\]|\\.)*)"', m.group(1))
    tables[lang] = dict(pairs)
ok = True
ref = set(tables['fr'])
for lang, t in tables.items():
    if set(t) != ref:
        ok = False
        print(f'{lang} : clés en trop {sorted(set(t) - ref)}, manquantes {sorted(ref - set(t))}')
fmt = lambda s: sorted(re.findall(r'%[@dsf]', s))
for k in sorted(ref):
    base = fmt(tables['fr'][k])
    for lang in ('en', 'es', 'it'):
        if fmt(tables[lang][k]) != base:
            ok = False
            print(f'format différent pour {k} en {lang} : {fmt(tables[lang][k])} au lieu de {base}')
print(f'{len(ref)} clés × 4 langues : ' + ('OK' if ok else 'ÉCHEC'))
sys.exit(0 if ok else 1)
