// Still to bring in on a box (One Vault W4): the box's own long import jobs, run and cancelled on the box, so they keep
// going with this page closed. `imports`: useBoxImports's answer.
import { StillToBringInView } from "../components/dashboard/StillToBringIn.jsx"

export const BoxStillToBringIn = ({ imports }) => <StillToBringInView {...imports} />
