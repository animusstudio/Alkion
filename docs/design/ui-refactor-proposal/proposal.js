const themeButtons = document.querySelectorAll('[data-theme-choice]');

for (const button of themeButtons) {
  button.addEventListener('click', () => {
    document.documentElement.dataset.theme = button.dataset.themeChoice;
    for (const choice of themeButtons) {
      choice.setAttribute('aria-pressed', String(choice === button));
    }
    document.dispatchEvent(new Event('proposal-theme-change'));
  });
}
