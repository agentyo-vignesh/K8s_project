# Intro diagram — prompt

Paste the block below into a diagram or image generator. It is self-contained.

Ithu moondru design ah oppitta pirahu vandhathu. Ovvonnum oru adversarial
fact-check ah kadanthathu, matrum moondrume "30 vinaadi la puriyanum" nu
sothanaiyil tholthathu — athanaala intha prompt la **vaarthai budget** oru
kaditthamaana kattupaadu. Vetuvathu than kadinamaana pangu.

Mukkiyamaana thiruttham: kadhavu 2 la **oru token IRUKU** (`aws eks get-token`
kodukira presigned STS URL). Munnadi "token illa" nu sonnathu thavaru.
Vithyaasam token illaamai illa — vithyaasam **yaaru saripaakiraan**.

---

```
Oru INTRO diagram uruvakunga. Ithu oru vaguppula mothal la kaatta padum, matrum
rendu mani neram andha padathai thirumba thirumba sutti kaattuvom. Athanaala
kaditthamaana kattupaadu: **30 vinaadila puriyanum**. Vilakkam thevai pattaa,
athu tholvi.

ONNU MATTUM SOLLA VENDIYATHU
  Moondru kadhavu iruku. Moondrulum oru token iruku. Vithyaasam - YAARU
  SARIPAAKIRAAN.
    kadhavu 1 : GitHub kaiyezhuthu podum   -> IAM saripaakum
    kadhavu 2 : AWS kaiyezhuthu podum      -> CLUSTER saripaakum
    kadhavu 3 : cluster kaiyezhuthu podum  -> IAM saripaakum
  Kadhavu 1 matrum 3 ORE VADIVAM ah irukanum - paarthavudan theriyanum.
  Kadhavu 2 andha "yaaru saripaakiraan" varisaiyil MATTUM vithyaasappadanum.

CANVAS
  Landscape 1920 x 1080. Vellai pinnani, karuppu mai. ORE accent vannam
  (indigo #3B4CCA), matrum athu **irandu idathula mattum** payanpadum -
  keezhea sollirukken. Vera vanname illa. Greyscale la print aanaalum
  ellaa vithyaasamum theriyanum.

AMAIPPU - moondru column, naalu rung, oru gutter, oru keezh band

  Idathu gutter (x 0-11%): naalu rung per, chinna sans, grey, valathu-neeti:
      YAARU KEKIRAAN
      ENNA KAATUKIRAAN
      YAARU SARIPAAKIRAAN
      ENNA THIRUMBUTHU
  Intha naalu vaarthai than padathai **varisaiyaa kuruke** padikka vaikkum,
  moondru thani odaiyaa illa. Ithu than intha padathin mukkiya karuvi.

  Moondru panel:
      panel 1  x 12-40%     KADHAVU 1 - GitHub workflow -> AWS
      panel 2  x 41-69%     KADHAVU 2 - pipeline -> Kubernetes API
      panel 3  x 70-98%     KADHAVU 3 - pod -> AWS (S3)
  Ovvoru panel um y 8-72%. Rung uyaram MOONDRU PANEL LUM ORE ALAVU:
      rung 1  y 14-27%
      rung 2  y 28-42%
      rung 3  y 43-58%
      rung 4  y 59-72%
  Panel talaippu y 8-13%. Ithu KATTAAYAM ore alavu - "ore vadivam" nu
  sollum urimai ithula than iruku.

  Keezh band (y 76-94%), muzhu agalam, "ODUM NERAM" nu talaippu:
      browser  ->  ALB  ->  nginx pod (port 80)
  Intha band ku mela oru melliya kodu, matrum "MELEA: ORE THADAVA AMAIPPU /
  KEEZHEA: OVVORU REQUEST" nu chinna grey ezhuthu. Intha pirivinai
  mukkiyam.

OVVORU CELL LA ENNA - 12 VAARTHAIKKU MELA VENAAM, ORU monospace sol mattum

  PANEL 1
    talaippu   KADHAVU 1 - GitHub workflow -> AWS
    rung 1     GitHub Actions runner
    rung 2     GitHub kaiyezhuthu potta JWT
    rung 3     IAM - Role-A oda trust policy
    rung 4     thaarkaalika credential, ~1 mani

  PANEL 2
    talaippu   KADHAVU 2 - pipeline -> Kubernetes API
    rung 1     kubectl (andha runner la)
    rung 2     aws eks get-token - presigned STS URL
    rung 3     CLUSTER oda access entry pattiyal
    rung 4     401 / 403 / vetri

  PANEL 3
    talaippu   KADHAVU 3 - pod -> AWS (S3)
    rung 1     initContainer, ServiceAccount demo/nginx-sa vazhiyaa
    rung 2     cluster kaiyezhuthu potta JWT
    rung 3     IAM - nginx-s3-reader oda trust policy
    rung 4     thaarkaalika credential

ANDHA "ENNA KAATUKIRAAN" RUNG - ithu than symmetry
  Panel 1 matrum panel 3 la, rung 2 la ORE VADIVAM: ore alavu ticket
  (rounded rectangle), moondru vari:
      panel 1                          panel 3
      issuer  token.actions...         issuer  oidc.eks.ap-south-1...
      aud     sts.amazonaws.com        aud     sts.amazonaws.com
      sub     repo:<owner>/<repo>:     sub     system:serviceaccount:
              ref:refs/heads/main              demo:nginx-sa
  Andha `sub` vari MATTUM accent vannathil. Padathula vera ethuvum accent
  vannathil illa - moondraam idam kidaiyaathu. Ithu than andha `sub` ah
  padathil sattamaana sol ah aakkum.

  Panel 2 la rung 2 la athey ticket vadivam, aana **accent vari illa** -
  moondru variyum karuppu:
      presigned STS GetCallerIdentity URL
      "naan Role-A"
      IAM identity, JWT illa
  Vadivam onnu, ullatakkam vera. Ithu than "moondrulum token iruku"
  nu sollum, matrum kadhavu 2 vera nu kaattum.

ANDHA "YAARU SARIPAAKIRAAN" RUNG - ithu than vithyaasam
  Panel 1 matrum panel 3: ore vadivam - HEXAGON, "IAM" nu perusaa,
  keezhea andha role per matrum "sub othu varanum".
  Panel 2: hexagon ILLA. Athukku pathilaa oru **rendu variyaana pattiyal**
  (ledger) - rendu vari, ovvonnum oru command:
      1  aws eks create-access-entry        <- "cluster ippo ivanai ariyum"
      2  aws eks associate-access-policy    <- "matrum ithu than seyya mudiyum"
  Andha pattiyal oru VERA VADIVAM ah irukanum: sathura mooligal, rendu
  paatha border. Hexagon polea ILLAAMA. Kaaranam ithu IAM illa.

  Andha rendu variyil irunthu rendu chinna kodu, panel 2 oda rung 4 ku:
      vari 1 la irunthu  ->  401  "andha ARN pattiyal la illa"      AUTHENTICATION
      vari 2 la irunthu  ->  403  "pattiyal la iruku, scope pothaathu"  AUTHORIZATION
  Intha rendu kodu KATTAAYAM. Ithu than 401 um 403 um yen vera nu
  vaarthai illaama kaattum.

RENDU VERA SERUMIDAM - ithu geography paadam
  Panel 1 matrum panel 3 oda vari, valathu pakkam, oru petti:
      AWS API endpoint  (STS . IAM . EKS . S3)
  Panel 2 oda vari, THANI petti, VERA IDATHULA:
      Kubernetes API server  -  ai-interview
  Intha rendu petti **onnu serndhu oru periya pettikkulla irukka koodaathu**.
  Rendum thooramaa, thanithani. Kaaranam:
      `aws eks update-kubeconfig` -> mothal pettikku pogum, VETRI
      `kubectl get nodes`         -> rendaam pettikku pogum, 401
  Intha rendu kodaiyum varainga, ovvonnum athu oda pettikku, matrum
  panel 2 la irunthu. Ithu than maanavan mika kuzhambura idam:
  ore command varisai, onnu jeyikkuthu, adutha varisai tholkkuthu.

SAAVI ILLAI - ithu theriyanum
  "ENNA KAATUKIRAAN" rung oda gutter la, andha vaarthaikku keezhea:
      oru dashed keyhole outline, oru saarina kodaal adikkapattu, keezhea:
      "AWS access key inga irukanum. Moondrulum illa."
  Ithu than padathula ulla ORE poottu-vadiva glyph. Vera engum key, lock,
  padlock icon varakoodaathu. Ore idathula irukirathaal athu oru
  mudivaana kooral ah padikkum, oru icon ah illa.

KODU VAKAI - vannam illaama vithyaasappadanum
  1  AWS API call        : melliya thodarcchi kodu, niraintha muk arrowhead
  2  Kubernetes API call : IRANDU inainthu melliya kodu (2pt idaiveli),
                           thirandha V arrowhead. Irattai ah irukirathaal
                           "vera oru server" nu solluthu.
  3  Token kaattuthal    : neelamaana dash (10 on, 5 off), rendu thalaiyum
                           thirandhu, naduvil andha ticket vadivam
  4  Admission la inject : melliya pulli kodu (2 on, 3 off), thirandha
                           melliya arrowhead. Kodu 3 ai vida melliya -
                           kaaranam inga onnum kekkapadalai
  5  Payload / traffic   : thadiyaana kodu (4pt), niraintha arrowhead.
                           Keezh band la mattum
  Vilaivu chip: 401 ku pongu octagon, 403 ku niraintha karuppu octagon,
  vetri ku rounded chip oru tick oda. Vadivam matrum nirappu - vannam illa.

  Legend ORE VARIYAA keezhea (y 96-99%), ainthu entry.

INJECT AAGUM PANGU - panel 3 la mattum, chinnathaa
  Panel 3 oda rung 1 la, ServiceAccount la irunthu andha initContainer ku
  oru pulli kodu (vakai 4), label:
      "mutating webhook - pod pirakkum nerathula"
  Andha kodu **ServiceAccount la irunthu**, Kubernetes API server la
  irunthu ILLA. Inject panrathu andha webhook.
  Andha kodu pakkathula chinna grey ezhuthu:
      "annotation ah maathinaa: kubectl rollout restart"

DO NOT - ithu ellaam kandippaa venaam
  - Panel 2 la HEXAGON venaam. Andha access entry ai kadhavu 1/3 oda
    checker polea vaikka koodaathu. Athu than intha muzhu padam
    sari panna vandha thappaana puriththal.
  - "token illa", "onnum kaatapadalai" nu panel 2 la ezhutha koodaathu.
    Anga oru token IRUKU.
  - Andha AWS API endpoint um Kubernetes API server um ore pettikkulla
    venaam, ore column lum venaam.
  - Keezh band la irunthu S3 ku oru kodu venaam. Andha browser request
    S3 ai thodaathu. S3 ai padipathu andha initContainer, pod pirakkum
    nerathula, MELEA panel 3 la.
  - ARN venaam. `--access-scope` flag venaam. IP address venaam.
    Muzhu error text venaam. Avai ellaam handout la irukum.
  - Cloud vendor logo venaam. 3D venaam. Nizhal venaam. Gradient venaam.
    Isometric venaam.
  - Mela sonna list la illaatha oru pettiyum, kodum, label um serkka
    koodaathu.
  - Ezhuthu 16px ku keezhea povathu koodaathu. Vaarthai athigam aanaal
    VETTUNGA, chinnathaa aakka koodaathu.
  - Oru label um innoru kodu mela ukkara koodaathu.

MUDIVU SOTHANAI
  Padathai moodi, oru maanavanidam kelunga: "credential engea
  sekarikkapadudhu?" Avan "engeyum illa - moondru idathula kekkum bothu
  pirakkuthu" nu sonnaal, padam velai seithathu.
```

---

## Yen intha vadivam

Moondru design ah oppitta pirahu, ovvonnula irunthu velai seyyurathu ithu:

| Design | Eduthathu |
|---|---|
| three-doors | Andha **gutter rung index** — padathai varisaiyaa kuruke padikka vaikkum. Moondru thani odai illa, oru oppeedu |
| swimlane | Andha **ore ticket vadivam rendu thadava** — symmetry ai vaarthai illaama sollum, matrum `sub` ai accent la vaithu sattamaana sol ah aakkum |
| layered-map | **Rendu thani serumidam** — "AWS API vs Kubernetes API" ai nyaabagam illaama, idam sambandhamaa aakkuthu |

Matrum moondrum tholthathula irunthu: **vaarthai budget**. 12 vaarthai per cell,
oru monospace sol per cell, ARN/flag/IP/muzhu error ellaam handout ku.

Andha rendu kodu — pattiyal vari 1 → 401, vari 2 → 403 — ithu oru verifier
kandupidichathu, matrum ithu thaan andha padathula mika payanulla pangu.
Rendu setup command, rendu tholvi, nerdiyaana joottu.
