/* Synthetic renderer fixture only, not a second result producer/consumer. */
static void ui_fixture_angles(debug_view_t *v,const doa_published_result_t *p)
{
 int64_t code=pl_fine_signed(&p->packet,PL_THETA_BIT,36);
 v->doa_angles=(doa_ui_angles_t){1,code,(double)code*180.0/(double)(UINT64_C(1)<<35),
     (double)code*180.0/(double)(UINT64_C(1)<<35),p->publish_seq,p->received_time,p->identity};
}
