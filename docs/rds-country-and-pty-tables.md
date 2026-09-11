# RDS Country Codes and Programme Types

Lookup tables shared by both apps: MPX Prime Studio sets these fields on air,
MPX Prime Meter decodes them off air. See the [Studio Settings and API
Reference](studio-settings-reference.md) for the keys that carry them (`rds_pi`,
`rds_ecc`, `rds_pty`) and the [Meter Operator Guide](meter-operator-guide.md) for how
they are displayed.

## RDS PI and ECC country table

RDS country identity is derived from:

- the top hex digit of the `PI` code, also called the country identifier or PI symbol
- the `ECC` value transmitted in group `1A`

Together they identify a country or area. There is no special "pirate" country code.

Group `1A` also carries the `LIC` language code (e.g. `15` Italian, `09` English, `0F` French, `08` German, `0A` Spanish, `1D` Dutch) and an optional Programme Item Number (PIN). PIN is off by default (transmits 0); enable it in **RDS -> Program -> Station Identity** to send the current programme item's scheduled day / hour / minute (config keys `pin_enabled`, `pin_day`, `pin_hour`, `pin_minute`). PIN is a legacy field that few modern receivers decode.

This appendix is a practical reference table for the published RDS country and area allocations. It is grouped the same way the published tables are grouped, so some countries and areas appear in more than one regional list.

### Europe / EBU area

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Albania | ALB | 9 | E0 |
| Algeria | ALG | 2 | E0 |
| Andorra | AND | 3 | E0 |
| Austria | AUT | A | E0 |
| Azores [Portugal] | AZR | 8 | E0 |
| Belgium | BEL | 6 | E0 |
| Belarus (ex-USSR) | BLR | F | E3 |
| Bosnia-Herzegovina (ex-Yugoslavia) | BIH | F | E4 |
| Bulgaria | BUL | 8 | E1 |
| Canaries [Spain] | CNR | E | E0 |
| Croatia (ex-Yugoslavia) | HRV | C | E3 |
| Cyprus | CYP | 2 | E1 |
| Czech Republic | CZE | 2 | E2 |
| Denmark | DNK | 9 | E1 |
| Egypt | EG | F | E0 |
| Estonia (ex-USSR) | EE | 2 | E4 |
| Faroe Islands [Denmark] | DK | 9 | E1 |
| Finland | FI | 6 | E1 |
| France | FR | F | E1 |
| Germany | DE | D or 1 | E0 |
| Gibraltar [United Kingdom] | GI | A | E1 |
| Greece | GR | 1 | E1 |
| Hungary | HU | B | E0 |
| Iceland | IS | A | E2 |
| Iraq | IQ | B | E1 |
| Ireland | IE | 2 | E3 |
| Israel | IL | 4 | E0 |
| Italy | IT | 5 | E0 |
| Jordan | JO | 5 | E1 |
| Latvia (ex-USSR) | LV | 9 | E3 |
| Lebanon | LB | A | E3 |
| Libya | LY | D | E1 |
| Liechtenstein | LI | 9 | E2 |
| Lithuania (ex-USSR) | LT | C | E2 |
| Luxembourg | LU | 7 | E1 |
| North Macedonia (ex-Yugoslavia) | MK | 4 | E3 |
| Madeira [Portugal] | PT | 8 | E2 |
| Malta | MT | C | E0 |
| Morocco | MA | 1 | E2 |
| Moldova (ex-USSR) | MD | 1 | E4 |
| Monaco | MC | B | E2 |
| Netherlands | NL | 8 | E3 |
| Norway | NO | F | E2 |
| Palestine | PS | 8 | E0 |
| Poland | PL | 3 | E2 |
| Portugal | PT | 8 | E4 |
| Romania | RO | E | E1 |
| Russian Federation (ex-USSR) | RU | 7 | E0 |
| San Marino | SM | 3 | E1 |
| Slovakia | SK | 5 | E2 |
| Slovenia (ex-Yugoslavia) | SI | 9 | E4 |
| Spain | ES | E | E2 |
| Sweden | SE | E | E3 |
| Switzerland | CH | 4 | E1 |
| Syrian Arab Republic | SY | 6 | E2 |
| Tunisia | TN | 7 | E2 |
| Turkey | TR | 3 | E3 |
| Ukraine (ex-USSR) | UA | 6 | E4 |
| United Kingdom | GB | C | E1 |
| Vatican | VA | 4 | E2 |
| Yugoslavia | YU | 6 | E3 |

### African broadcasting area

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Ascension Island | - | A | D1 |
| Cabinda | - | 4 | D3 |
| Angola | AO | 6 | D0 |
| Algeria | DZ | 2 | E0 |
| Burundi | BI | 9 | D1 |
| Benin | BJ | E | D0 |
| Burkina Faso | BF | B | D0 |
| Botswana | BW | B | D1 |
| Cameroon | CM | 1 | D0 |
| Canary Islands [Spain] | ES | E | E0 |
| Central African Republic | CF | 2 | D0 |
| Chad | TD | 9 | D2 |
| Congo | CG | C | D0 |
| Comoros | KM | C | D1 |
| Cape Verde | CV | 6 | D1 |
| Cote d'Ivoire | CI | C | D2 |
| Djibouti | DJ | 3 | D0 |
| Egypt | EG | F | E0 |
| Ethiopia | ET | E | D1 |
| Gabon | GA | 8 | D0 |
| Ghana | GH | 3 | D1 |
| Gambia | GM | 8 | D1 |
| Guinea-Bissau | GW | A | D2 |
| Equatorial Guinea | GQ | 7 | D0 |
| Republic of Guinea | GN | 9 | D0 |
| Kenya | KE | 6 | D2 |
| Liberia | LR | 2 | D1 |
| Libya | LY | D | E1 |
| Lesotho | LS | 6 | D3 |
| Mauritius | MU | A | D3 |
| Madagascar | MG | 4 | D0 |
| Mali | ML | 5 | D0 |
| Mozambique | MZ | 3 | D2 |
| Morocco | MA | 1 | E2 |
| Mauritania | MR | 4 | D1 |
| Malawi | MW | F | D0 |
| Niger | NE | 8 | D2 |
| Nigeria | NG | F | D1 |
| Namibia | NA | 1 | D1 |
| Rwanda | RW | 5 | D3 |
| Sao Tome and Principe | ST | 5 | D1 |
| Seychelles | SC | 8 | D3 |
| Senegal | SN | 7 | D1 |
| Sierra Leone | SL | 1 | D2 |
| Somalia | SO | 7 | D2 |
| South Africa | ZA | A | D0 |
| Sudan | SD | C | D3 |
| Swaziland | SZ | 5 | D2 |
| Togo | TG | D | D0 |
| Tunisia | TN | 7 | E2 |
| Tanzania | TZ | D | D1 |
| Uganda | UG | 4 | D2 |
| Western Sahara | EH | 3 | D3 |
| Zaire | ZR | B | D2 |
| Zambia | ZM | E | D2 |
| Zanzibar | - | D | D2 |
| Zimbabwe | ZW | 2 | D2 |

### Former Soviet Union allocations

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Armenia | AM | A | E4 |
| Azerbaijan | AZ | B | E3 |
| Belarus | BY | F | E3 |
| Estonia | EE | 2 | E4 |
| Georgia | GE | C | E4 |
| Kazakhstan | KZ | D | E3 |
| Kyrgyzstan | KG | 3 | E4 |
| Latvia | LV | 9 | E3 |
| Lithuania | LT | C | E2 |
| Moldova | MD | 1 | E4 |
| Russian Federation | RU | 7 | E0 |
| Tajikistan | TJ | 5 | E3 |
| Turkmenistan | TM | E | E4 |
| Ukraine | UA | 6 | E4 |
| Uzbekistan | UZ | B | E4 |

### ITU Region 2

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Anguilla | AI | 1 | A2 |
| Antigua and Barbuda | AG | 2 | A2 |
| Argentina | AR | A | A2 |
| Aruba | AW | 3 | A4 |
| Bahamas | BS | F | A2 |
| Barbados | BB | 5 | A2 |
| Belize | BZ | 6 | A2 |
| Bermuda | BM | C | A2 |
| Bolivia | BO | 1 | A3 |
| Brazil | BR | B | A2 |
| Canada | CA | C | A1 |
| Cayman Islands | KY | 7 | A2 |
| Chile | CL | C | A3 |
| Colombia | CO | 2 | A3 |
| Costa Rica | CR | 8 | A2 |
| Cuba | CU | 9 | A2 |
| Dominica | DM | A | A3 |
| Dominican Republic | DO | B | A3 |
| Ecuador | EC | 3 | A2 |
| El Salvador | SV | C | A4 |
| Falkland Islands | FK | 4 | A2 |
| Greenland | GL | F | A1 |
| Grenada | GD | D | A3 |
| Guadeloupe | GP | E | A2 |
| Guatemala | GT | 1 | A4 |
| Guiana | GF | 5 | A3 |
| Guyana | GY | F | A3 |
| Haiti | HT | D | A4 |
| Honduras | HN | 2 | A4 |
| Jamaica | JM | 3 | A3 |
| Martinique | MQ | 4 | A3 |
| Mexico | MX | F | A4 |
| Montserrat | MS | 5 | A4 |
| Netherlands Antilles | AN | D | A2 |
| Nicaragua | NI | 7 | A3 |
| Panama | PA | 9 | A3 |
| Paraguay | PY | 6 | A3 |
| Peru | PE | 7 | A4 |
| Puerto Rico | PR | 8 | A3 |
| Saint Kitts | KN | A | A4 |
| Saint Lucia | LC | B | A4 |
| St Pierre and Miquelon | PM | F | A6 |
| Saint Vincent | VC | C | A5 |
| Suriname | SR | 8 | A4 |
| Trinidad and Tobago | TT | 6 | A4 |
| Turks and Caicos Islands | TC | E | A3 |
| United States of America | US | 1..9, A, B, D, E | A0 |
| Uruguay | UY | 9 | A4 |
| Venezuela | VE | E | A4 |
| Virgin Islands [British] | VG | F | A5 |
| Virgin Islands [USA] | VI | F | A5 |

### ITU Region 3

| Country or area | ISO | PI symbol | ECC |
| --- | --- | --- | --- |
| Afghanistan | AF | A | F0 |
| Saudi Arabia | SA | 9 | F0 |
| Australia - Australian Capital Territory | - | 1 | F0 |
| Australia - New South Wales | - | 2 | F0 |
| Australia - Victoria | - | 3 | F0 |
| Australia - Queensland | - | 4 | F0 |
| Australia - South Australia | - | 5 | F0 |
| Australia - Western Australia | - | 6 | F0 |
| Australia - Tasmania | - | 7 | F0 |
| Australia - Northern Territory | - | 8 | F0 |
| Bangladesh | BD | 3 | F1 |
| Bahrain | BH | E | F0 |
| Myanmar [Burma] | MM | B | F0 |
| Brunei Darussalam | BN | B | F1 |
| Bhutan | BT | 2 | F1 |
| Cambodia | KH | 3 | F2 |
| China | CN | C | F0 |
| Sri Lanka | LK | C | F1 |
| Fiji | FJ | 5 | F1 |
| Hong Kong | HK | F | F1 |
| India | IN | 5 | F2 |
| Indonesia | ID | C | F2 |
| Iran | IR | 8 | F0 |
| Iraq | IQ | B | E1 |
| Japan | JP | 9 | F2 |
| Kiribati | KI | 1 | F1 |
| Korea [South] | KR | E | F1 |
| Korea [North] | KP | D | F0 |
| Kuwait | KW | 1 | F2 |
| Laos | LA | 1 | F3 |
| Macau | MO | 6 | F2 |
| Malaysia | MY | F | F0 |
| Maldives | MV | B | F2 |
| Micronesia | FM | E | F3 |
| Mongolia | MN | F | F3 |
| Nepal | NP | E | F2 |
| Nauru | NR | 7 | F1 |
| New Zealand | NZ | 9 | F1 |
| Oman | OM | 6 | F1 |
| Pakistan | PK | 4 | F1 |
| Philippines | PH | 8 | F2 |
| Papua New Guinea | PG | 9 | F3 |
| Qatar | QA | 2 | F2 |
| Solomon Islands | SB | A | F1 |
| Western Samoa | WS | 4 | F2 |
| Singapore | SG | A | F2 |
| Taiwan | TW | D | F1 |
| Thailand | TH | 2 | F3 |
| Tonga | TO | 3 | F3 |
| UAE | AE | D | F2 |
| Vietnam | VN | 7 | F2 |
| Vanuatu | VU | F | F2 |
| Yemen | YE | B | F3 |

### Notes

- The `PI symbol` is the top hex digit of the four-digit `PI` code.
- The remaining three hex digits identify the programme service within the country or area allocation.
- The United States uses `RBDS` PI allocation rules, so the country row above is only the country-area level identifier.
- Australia commonly uses a state-based `PI` symbol scheme in practice, which is why the published list is shown by state and territory rather than one national symbol.

## RDS programme type (PTY) codes

`PTY` is a 5-bit programme-type ("genre") code carried in every group. The code
is the same field worldwide, but **Europe (RDS) and North America (RBDS) assign
different genres to the same number** -- there is no in-band flag telling a
receiver which table to use, so receivers pick by region. The **PTY Region**
toggle on the RDS -> Program tab (web dashboard: Identity page; `Europe (RDS)` / `USA (RBDS)`, INI key
`pty_rbds`) switches which table labels the picker and the status display; the
transmitted 5-bit code is identical either way. Pick the table that matches your
audience -- e.g. code 10 reads as `Pop Music` on an RDS receiver but `Country` on
an RBDS receiver.

### Europe (RDS, EN 50067 / IEC 62106)

| Code | Programme type | Code | Programme type |
| ---: | :------------- | ---: | :------------- |
| 0 | None / undefined | 16 | Weather |
| 1 | News | 17 | Finance |
| 2 | Current Affairs | 18 | Children's programmes |
| 3 | Information | 19 | Social Affairs |
| 4 | Sport | 20 | Religion |
| 5 | Education | 21 | Phone-In |
| 6 | Drama | 22 | Travel |
| 7 | Culture | 23 | Leisure |
| 8 | Science | 24 | Jazz Music |
| 9 | Varied | 25 | Country Music |
| 10 | Pop Music | 26 | National Music |
| 11 | Rock Music | 27 | Oldies Music |
| 12 | Easy Listening | 28 | Folk Music |
| 13 | Light Classical | 29 | Documentary |
| 14 | Serious Classical | 30 | Alarm Test |
| 15 | Other Music | 31 | Alarm (emergency) |

### North America (RBDS, NRSC-4-B)

| Code | Programme type | Code | Programme type |
| ---: | :------------- | ---: | :------------- |
| 0 | None / undefined | 16 | Rhythm and Blues |
| 1 | News | 17 | Soft Rhythm and Blues |
| 2 | Information | 18 | Language (Foreign) |
| 3 | Sports | 19 | Religious Music |
| 4 | Talk | 20 | Religious Talk |
| 5 | Rock | 21 | Personality |
| 6 | Classic Rock | 22 | Public |
| 7 | Adult Hits | 23 | College |
| 8 | Soft Rock | 24 | Spanish Talk |
| 9 | Top 40 | 25 | Spanish Music |
| 10 | Country | 26 | Hip-Hop |
| 11 | Oldies | 27 | Unassigned |
| 12 | Soft | 28 | Unassigned |
| 13 | Nostalgia | 29 | Weather |
| 14 | Jazz | 30 | Emergency Test |
| 15 | Classical | 31 | Emergency (ALERT!) |

Notes:

- Codes 30 / 31 are reserved for emergency use in both tables (test + live
  alert) and should not be used for normal programming.
- RBDS codes 24 / 25 / 26 (`Spanish Talk` / `Spanish Music` / `Hip-Hop`) were
  added in later NRSC-4 revisions; older receivers may show them as
  `Unassigned`.
- Receivers display short (8-character) and long (16-character) abbreviations of
  these names; the exact wording varies by manufacturer, but the code-to-genre
  mapping is fixed by the standard.
