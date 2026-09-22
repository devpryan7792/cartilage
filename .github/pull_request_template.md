## Description
Briefly describe your changes or the new appliance recipe you are contributing.

## Type of Change
- [ ] 🎮 New Appliance Recipe (`recipes/<name>.yaml`)
- [ ] 🧪 Alpine Linux Musl Recipe
- [ ] ⚡ CLI / Build Tooling improvement
- [ ] 📖 Documentation / Asset improvement
- [ ] 🐛 Bug fix

## Verification Checklist
Before submitting, please ensure you have tested your change locally:
- [ ] Recipe passes schema validation: `./cartilage validate recipes/<name>.yaml`
- [ ] Appliance boots and runs in QEMU: `./cartilage run recipes/<name>.yaml`
- [ ] All tests pass: `./scripts/15_test_cartilage_cli.sh`
