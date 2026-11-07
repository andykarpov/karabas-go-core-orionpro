# Ядро Орион-ПРО для Karabas Go / Mini / Mini G

Ядро советского домашнего компьютера Орион-ПРО («Орионсофт», 1993–2000) для плат семейства Karabas Go (Xilinx Spartan-6 XC6SLX25). Собрано для всех трёх плат; проверено на Mini G, на Go и Mini ещё не запускалось. Родственное ядро: [karabas-go-core-orion128](https://github.com/andykarpov/karabas-go-core-orion128).

Что работает: Z80 на 2,5 / 5 / 10 МГц, ОЗУ до 2 МБ с диспетчером памяти, встроенные ROM1 / ROM2 3.21, меню BIOS, Монитор и тесты, режим совместимости Орион-128 с оболочкой ROM2, экраны Ориона-128 и 16-цветные режимы с палитрой Мультикарты, клавиатуры РК-86 и MS7007, два дисковода (`.odi`), жёсткие диски IDE, часы платы, AY, мышь Мультикарты (USB-мышь), COM1 через прошивку. С образа дискеты загружается AltairDOS / Best-DOS.

- [docs/GUIDE.md](docs/GUIDE.md): **как пользоваться**: что положить на SD-карту, как собрать системную дискету, что в каком порядке загружать.
- [docs/PLAN.md](docs/PLAN.md): исследование, решения и фазы.
- [docs/HARDWARE.md](docs/HARDWARE.md): поддерживаемое железо, карта памяти и порты.
- [docs/BACKLOG.md](docs/BACKLOG.md): открытые вопросы и находки.

Клонировать с `--recursive`: модули плат лежат в сабмодуле `modules/` ([karabas-go-modules](https://github.com/andykarpov/karabas-go-modules)). Для `src/make_core.py` рядом нужен [karabas-go-tools](https://github.com/andykarpov/karabas-go-tools).

ROM1 и ROM2 3.21 взяты из [OriZEmu](https://github.com/serge-404/OriZEmu); поведение портов как в OriZEmu в режиме v3.20.

Лицензия: GPL v3.
