import DefaultTheme from 'vitepress/theme';

// rainbow.css must load first: vars.css consumes the brand variables it
// defines (--vp-c-brand-next, --vp-c-brand-light, --vp-c-brand-darker),
// and CSS resolves them in load order.
import './vendor/escrcpy/rainbow.css';
import './vendor/escrcpy/vars.css';
import './custom.css';

export default DefaultTheme;
