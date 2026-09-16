import DefaultTheme from 'vitepress/theme';

// rainbow.css first: vars.css consumes the brand variables it defines.
import './vendor/escrcpy/rainbow.css';
import './vendor/escrcpy/vars.css';
import './custom.css';

export default DefaultTheme;
