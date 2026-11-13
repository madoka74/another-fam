# 어나더 팸 (Another Fam)

비전프로에서 현실 공간에 사는 강아지를 태어난 순간부터 키우는 앱. Blankish works.

- 하루는 현실과 같은 24시간, 나이는 현실 하루에 26일 (13년 = 약 6달, 그 뒤로는 그 모습 그대로)
- `ios/` 앱 소스 (XcodeGen), `tools/` 모델·움직임·소리·아이콘을 만드는 파이썬 도구 (결과물은 `ios/AnotherFam/Model`, `Sounds` 에 들어 있음 — 빌드 때는 돌리지 않음)
- GitHub 에 올리면 Actions 가 빌드해 TestFlight 로 올림 (`.github/workflows/ios.yml`, 다른 앱과 같은 Secrets)
